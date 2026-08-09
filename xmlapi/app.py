#!/usr/bin/env python3
"""
FreeSWITCH XML API Service
Provides directory and dialplan from PostgreSQL database
"""

from flask import Flask, request, Response
from xml.sax.saxutils import quoteattr
import psycopg2
from psycopg2.extras import RealDictCursor
import os
import logging

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Database configuration from environment.
#
# POSTGRES_PASSWORD icin BILEREK varsayilan yok: sirlar yalnizca .env'den
# gelmeli. Eskiden burada os.getenv('POSTGRES_PASSWORD', 'kamailio') vardi —
# bu, yanlis/eksik yapilandirmada sessizce yanlis bir sifreyle baglanmaya
# calisirdi (ve o sifre .env'deki gercek degerle uyusmazsa DB baglantisi
# sessizce basarisiz olup uygulama "unhealthy" gorunurdu, ama NEDENI gizli
# kalirdi). Simdi eksikse islem derhal ve acikca patlar.
_POSTGRES_PASSWORD = os.getenv('POSTGRES_PASSWORD')
if not _POSTGRES_PASSWORD:
    raise RuntimeError(
        "POSTGRES_PASSWORD ortam degiskeni tanimli degil. Sirlar yalnizca "
        ".env uzerinden saglanmalidir; varsayilan sifre KULLANILMIYOR."
    )

DB_CONFIG = {
    'host': os.getenv('POSTGRES_HOST', 'postgres'),
    'port': os.getenv('POSTGRES_PORT', '5432'),
    'database': os.getenv('POSTGRES_DB', 'kamailio'),
    'user': os.getenv('POSTGRES_USER', 'kamailio'),
    'password': _POSTGRES_PASSWORD,
}

def get_db():
    """Get database connection"""
    try:
        return psycopg2.connect(
            **DB_CONFIG,
            cursor_factory=RealDictCursor,
            connect_timeout=3
        )
    except Exception as e:
        logger.error(f"Database connection failed: {e}")
        raise

# FreeSWITCH'e "bulunamadi" bildiren belge. HTTP 200 ile donuyor: mod_xml_curl
# icin bu bir hata degil, "bu kaynaktan cevap yok" anlamina gelir ve FreeSWITCH
# baska bir binding/statik konfigurasyona bakmaya devam eder.
EMPTY_XML = (
    '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
    '<document type="freeswitch/xml">\n'
    '  <section name="result">\n'
    '    <result status="not found"/>\n'
    '  </section>\n'
    '</document>'
)


def empty_xml_response():
    """Return empty/not-found XML response"""
    return Response(EMPTY_XML, mimetype='application/xml')


def _attr(value):
    """XML oznitelik degeri: tirnaklar dahil, tamamen kacisli (escaped).

    quoteattr hem ozel karakterleri (< > & " ') kacirir hem de sonucu
    tirnak icine alir; cagiran taraf ayrica tirnak eklemez.
    """
    return quoteattr('' if value is None else str(value))


@app.route('/fs/directory', methods=['GET', 'POST'])
def directory():
    """
    FreeSWITCH directory lookup.

    Kimlik dogrulamayi Kamailio (digest auth ile) yapiyor ve FreeSWITCH
    internal sofia profili auth-calls=false ile calisiyor; bu yuzden SIP
    sifresi BILEREK donulmuyor (once buradan cleartext donuyordu).

    tenant_id her zaman bir <variable> olarak eklenir; opsiyonel alanlar
    null olsa bile bu deger hic eksik olmaz (fs_directory view'i tenants ile
    INNER JOIN oldugu icin tenant_id hicbir zaman NULL degildir) — Task 10
    CDR satirlarini buna gore tenant'a atfedecek.
    """
    params = request.values.to_dict()
    user = params.get('user')
    domain = params.get('domain')

    logger.info(f"Directory request: user={user}, domain={domain}")

    if not user or not domain:
        logger.warning("directory: user/domain eksik")
        return empty_xml_response()

    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT tenant_id, tenant_code, "effective_caller_id_name",
                   "effective_caller_id_number", "dial-string", "max-calls",
                   "codec-prefs", "call-timeout", "vm-enabled",
                   "forward-destination"
            FROM fs_directory
            WHERE "user" = %s AND domain = %s
            """,
            (user, domain),
        )
        row = cur.fetchone()
        cur.close()
        conn.close()
    except Exception as exc:
        logger.error("directory sorgu hatasi: %s", exc)
        return empty_xml_response()

    if not row:
        logger.info("directory: bulunamadi %s@%s", user, domain)
        return empty_xml_response()

    variables = [
        ('tenant_id', row['tenant_id']),
        ('tenant_code', row['tenant_code']),
        ('effective_caller_id_name', row['effective_caller_id_name']),
        ('effective_caller_id_number', row['effective_caller_id_number']),
        ('max_calls', row['max-calls']),
        ('codec_prefs', row['codec-prefs']),
        ('call_timeout', row['call-timeout']),
        ('voicemail_enabled', row['vm-enabled']),
    ]
    if row['forward-destination']:
        variables.append(('forward_destination', row['forward-destination']))

    var_xml = '\n'.join(
        '          <variable name={} value={}/>'.format(_attr(n), _attr(v))
        for n, v in variables
    )

    xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
        '<document type="freeswitch/xml">\n'
        '  <section name="directory">\n'
        '    <domain name={}>\n'
        '      <user id={}>\n'
        '        <params>\n'
        '          <param name="dial-string" value={}/>\n'
        '        </params>\n'
        '        <variables>\n'
        '{}\n'
        '        </variables>\n'
        '      </user>\n'
        '    </domain>\n'
        '  </section>\n'
        '</document>'
    ).format(_attr(domain), _attr(user), _attr(row['dial-string']), var_xml)

    logger.info("directory ok: %s@%s", user, domain)
    return Response(xml, mimetype='application/xml')


@app.route('/fs/dialplan', methods=['GET', 'POST'])
def dialplan():
    """
    FreeSWITCH dialplan lookup.

    GUVENLIK NOTU: dialplan.actions sutunu ham XML fragment olarak
    gomulur, kacirilmaz. Bu sutuna yalnizca yonetici tarafindan
    dogrulanmis icerik yazilmalidir; bu sutun bir kod-enjeksiyonu
    yuzeyidir ve kullanici girdisinden asla doldurulmamalidir.
    """
    params = request.values.to_dict()
    context = params.get('Hunt-Context', 'default')
    destination = params.get('Hunt-Destination-Number', '')
    caller_id = params.get('Caller-Caller-ID-Number', '')

    logger.info(f"Dialplan request: context={context}, destination={destination}, caller={caller_id}")

    if not destination:
        logger.warning("dialplan: hedef numara eksik")
        return empty_xml_response()

    try:
        conn = get_db()
        cur = conn.cursor()

        # Query dialplan rules (ordered by priority)
        cur.execute("""
            SELECT
                id,
                tenant_code,
                context,
                destination_number,
                priority,
                field,
                expression,
                actions,
                description
            FROM fs_dialplan
            WHERE context = %s
              AND %s ~ destination_number
            ORDER BY priority, id
            LIMIT 10
        """, (context, destination))

        rules = cur.fetchall()
        cur.close()
        conn.close()
    except Exception as exc:
        logger.error("dialplan sorgu hatasi: %s", exc)
        return empty_xml_response()

    if not rules:
        logger.info(f"dialplan: {context} baglaminda {destination} icin kural yok")
        return empty_xml_response()

    extensions = []
    for rule in rules:
        # actions kasitli olarak _attr()'dan gecmiyor: ham XML fragment
        # olarak gomuluyor (bkz. yukaridaki GUVENLIK NOTU).
        extensions.append(
            '      <extension name={} continue="false">\n'
            '        <condition field="destination_number" expression={}>\n'
            '          {}\n'
            '        </condition>\n'
            '      </extension>'.format(
                _attr('db-rule-{}'.format(rule['id'])),
                _attr(rule['destination_number']),
                rule['actions'],
            )
        )

    xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
        '<document type="freeswitch/xml">\n'
        '  <section name="dialplan">\n'
        '    <context name={}>\n'
        '{}\n'
        '    </context>\n'
        '  </section>\n'
        '</document>'
    ).format(_attr(context), '\n'.join(extensions))

    logger.info(f"dialplan ok: {len(rules)} kural, {destination}")
    return Response(xml, mimetype='application/xml')

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        return {'status': 'healthy', 'database': 'connected'}, 200
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return {'status': 'unhealthy', 'error': str(e)}, 503

@app.route('/', methods=['GET'])
def index():
    """API information"""
    return {
        'service': 'FreeSWITCH XML API',
        'version': '1.0',
        'endpoints': {
            '/fs/directory': 'User directory lookup',
            '/fs/dialplan': 'Dialplan routing',
            '/health': 'Health check'
        }
    }

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)
