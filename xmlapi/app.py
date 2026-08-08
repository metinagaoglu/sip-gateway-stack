#!/usr/bin/env python3
"""
FreeSWITCH XML API Service
Provides directory and dialplan from PostgreSQL database
"""

from flask import Flask, request, Response
import psycopg2
from psycopg2.extras import RealDictCursor
import os
import logging

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Database configuration from environment
DB_CONFIG = {
    'host': os.getenv('POSTGRES_HOST', 'postgres'),
    'port': os.getenv('POSTGRES_PORT', '5432'),
    'database': os.getenv('POSTGRES_DB', 'kamailio'),
    'user': os.getenv('POSTGRES_USER', 'kamailio'),
    'password': os.getenv('POSTGRES_PASSWORD', 'kamailio')
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

def empty_xml_response():
    """Return empty XML response"""
    return Response(
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
        '<document type="freeswitch/xml"></document>',
        mimetype='application/xml'
    )

@app.route('/fs/directory', methods=['GET', 'POST'])
def directory():
    """
    FreeSWITCH Directory Lookup
    Returns user authentication and configuration
    """
    # Get parameters from FreeSWITCH
    params = request.values.to_dict()
    user = params.get('user')
    domain = params.get('domain')

    logger.info(f"Directory request: user={user}, domain={domain}")

    if not user or not domain:
        logger.warning("Missing user or domain parameter")
        return empty_xml_response()

    try:
        conn = get_db()
        cur = conn.cursor()

        # Query fs_directory view
        cur.execute("""
            SELECT
                "user",
                domain,
                tenant_code,
                password,
                "effective_caller_id_name",
                "effective_caller_id_number",
                "dial-string",
                "max-calls",
                "codec-prefs",
                "call-timeout",
                "vm-enabled",
                "vm-password",
                "forward-destination"
            FROM fs_directory
            WHERE "user" = %s AND domain = %s
        """, (user, domain))

        user_data = cur.fetchone()
        cur.close()
        conn.close()

        if not user_data:
            logger.warning(f"User not found: {user}@{domain}")
            return empty_xml_response()

        # Generate FreeSWITCH XML
        xml = f"""<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document type="freeswitch/xml">
  <section name="directory">
    <domain name="{domain}">
      <user id="{user}">
        <params>
          <param name="password" value="{user_data['password']}"/>
          <param name="dial-string" value="{user_data['dial-string']}"/>
        </params>
        <variables>
          <variable name="tenant_code" value="{user_data['tenant_code']}"/>
          <variable name="effective_caller_id_name" value="{user_data['effective_caller_id_name']}"/>
          <variable name="effective_caller_id_number" value="{user_data['effective_caller_id_number']}"/>
          <variable name="max_calls" value="{user_data['max-calls']}"/>
          <variable name="codec_prefs" value="{user_data['codec-prefs']}"/>
          <variable name="call_timeout" value="{user_data['call-timeout']}"/>
          <variable name="voicemail_enabled" value="{user_data['vm-enabled']}"/>
"""

        # Add optional variables
        if user_data['vm-password']:
            xml += f"""          <variable name="voicemail_password" value="{user_data['vm-password']}"/>
"""
        if user_data['forward-destination']:
            xml += f"""          <variable name="forward_destination" value="{user_data['forward-destination']}"/>
"""

        xml += """        </variables>
      </user>
    </domain>
  </section>
</document>"""

        logger.info(f"Directory lookup successful: {user}@{domain}")
        return Response(xml, mimetype='application/xml')

    except Exception as e:
        logger.error(f"Directory lookup error: {e}")
        return empty_xml_response()

@app.route('/fs/dialplan', methods=['GET', 'POST'])
def dialplan():
    """
    FreeSWITCH Dialplan Lookup
    Returns routing rules from database
    """
    # Get parameters from FreeSWITCH
    params = request.values.to_dict()
    context = params.get('Hunt-Context', 'default')
    destination = params.get('Hunt-Destination-Number', '')
    caller_id = params.get('Caller-Caller-ID-Number', '')

    logger.info(f"Dialplan request: context={context}, destination={destination}, caller={caller_id}")

    if not destination:
        logger.warning("Missing destination number")
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

        if not rules:
            logger.info(f"No dialplan rule found for {destination} in context {context}")
            return empty_xml_response()

        # Build XML with all matching rules
        xml = f"""<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document type="freeswitch/xml">
  <section name="dialplan">
    <context name="{context}">
"""

        for rule in rules:
            xml += f"""      <extension name="db-rule-{rule['id']}" continue="false">
        <condition field="destination_number" expression="{rule['destination_number']}">
          {rule['actions']}
        </condition>
      </extension>
"""

        xml += """    </context>
  </section>
</document>"""

        logger.info(f"Dialplan lookup successful: {len(rules)} rules for {destination}")
        return Response(xml, mimetype='application/xml')

    except Exception as e:
        logger.error(f"Dialplan lookup error: {e}")
        return empty_xml_response()

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
