#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- restore guard: eger display_name'i test icin bozarsak, script hangi
#     asamada basarisiz olursa olsun (assertion, ctrl-c, beklenmedik hata)
#     EXIT trap'i satirin orijinal degerini geri yazar. Bir sonraki task
#     bozuk seed veriyi devralmasin diye bu, "basarili yol"un sonuna degil,
#     trap'e baglanir.
DISPLAY_NAME_DIRTY=0
restore_display_name() {
  if [ "$DISPLAY_NAME_DIRTY" = "1" ]; then
    docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
      "UPDATE subscriber SET display_name='Alice' WHERE username='alice';" >/dev/null 2>&1 || true
  fi
}
trap restore_display_name EXIT

docker compose up -d xmlapi

HEALTHY=0
for i in $(seq 1 30); do
  if docker compose exec -T xmlapi curl -sf http://localhost:8080/health >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 2
done
[ "$HEALTHY" = "1" ] || fail "xmlapi /health 60 saniye icinde saglikli yanit vermedi"

# freeswitch onceden (bu degisiklikten once) calisir durumda olabilir; bind
# mount sayesinde yeni render edilmis xml_curl.conf.xml'i gorse bile,
# mod_xml_curl'in gateway-url/credentials ayarlarini SADECE modul yuklenirken
# (yani surec baslarken) okur. --force-recreate ile freeswitch'i tazeden
# baslatarak entrypoint.sh'nin sablonu yeniden render etmesini VE
# mod_xml_curl'in artik saglikli olan xmlapi'ye karsi taze yapilandirmayla
# yuklenmesini garantiliyoruz — aksi halde bu test, freeswitch'in eski/onceki
# bir calisma anindan kalma durumuyla sessizce (vacuously) gecebilirdi.
docker compose up -d --force-recreate freeswitch

FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
FS_READY=0
for i in $(seq 1 30); do
  if $FSCLI "status" >/dev/null 2>&1; then
    FS_READY=1
    break
  fi
  sleep 2
done
[ "$FS_READY" = "1" ] || fail "freeswitch yeniden baslatildiktan sonra fs_cli baglanamiyor"

D=$(docker compose exec -T xmlapi curl -s -X POST http://localhost:8080/fs/directory \
      -d "user=alice" -d "domain=tenant1.voip.local")

echo "$D" | grep -q '<user id="alice"'  || fail "directory alice dondurmedi"
echo "$D" | grep -q 'name="tenant_id"'  || fail "tenant_id degiskeni yok (CDR icin gerekli)"
echo "$D" | grep -q 'name="password"'   && fail "directory hala cleartext sifre donduruyor"

# XML gecerliligi — gercekten parse ediliyor, sadece grep degil.
echo "$D" | docker compose exec -T xmlapi python3 -c \
  "import sys, xml.dom.minidom; xml.dom.minidom.parseString(sys.stdin.read())" \
  || fail "directory yaniti gecerli XML degil"

# Bilinmeyen kullanici bos belge dondurmeli, 500 degil.
U=$(docker compose exec -T xmlapi curl -s -o /dev/null -w "%{http_code}" \
      -X POST http://localhost:8080/fs/directory -d "user=yok" -d "domain=tenant1.voip.local")
[ "$U" = "200" ] || fail "bilinmeyen kullanicida HTTP $U dondu, 200 bekleniyordu"

# dialplan da eslesme yoksa 500 degil 200 + gecerli (bos) XML dondurmeli —
# ayni "not found" sozlesmesi directory ile aynen paylasilmali.
P=$(docker compose exec -T xmlapi curl -s -o /dev/null -w "%{http_code}" \
      -X POST http://localhost:8080/fs/dialplan -d "Hunt-Destination-Number=99999999999999")
[ "$P" = "200" ] || fail "dialplan eslesmeyen numarada HTTP $P dondu, 200 bekleniyordu"
PX=$(docker compose exec -T xmlapi curl -s \
      -X POST http://localhost:8080/fs/dialplan -d "Hunt-Destination-Number=99999999999999")
echo "$PX" | docker compose exec -T xmlapi python3 -c \
  "import sys, xml.dom.minidom; xml.dom.minidom.parseString(sys.stdin.read())" \
  || fail "dialplan (bos) yaniti gecerli XML degil"

# --- XML kacisi: ozel karakter iceren display_name bozmamali, VE degerin
#     kendisi de kayipsiz/degistirilmeden (round-trip) geri gelmeli. Sadece
#     "parse hatasi vermiyor" yeterli degil — quoteattr yerine yanlislikla
#     icerigi sessizce kirpan/degistiren bir kod da parse'i gecebilirdi.
DISPLAY_NAME_DIRTY=1
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "UPDATE subscriber SET display_name='A \"B\" & <C>' WHERE username='alice';" >/dev/null

E=$(docker compose exec -T xmlapi curl -s -X POST http://localhost:8080/fs/directory \
      -d "user=alice" -d "domain=tenant1.voip.local")

ROUNDTRIP_CHECK=$(cat <<'PY'
import os, sys, xml.dom.minidom as M

doc = M.parseString(os.environ["XML_DOC"])
nodes = doc.getElementsByTagName("variable")
values = [n.getAttribute("value") for n in nodes
          if n.getAttribute("name") == "effective_caller_id_name"]
if not values:
    print("effective_caller_id_name degiskeni yaniti icinde yok", file=sys.stderr)
    sys.exit(1)
expected = os.environ["EXPECTED_VALUE"]
if values[0] != expected:
    print(f"kacis degeri bozmus: got={values[0]!r} want={expected!r}", file=sys.stderr)
    sys.exit(1)
PY
)

docker compose exec -T -e XML_DOC="$E" -e EXPECTED_VALUE='A "B" & <C>' xmlapi \
  python3 -c "$ROUNDTRIP_CHECK" \
  || fail "ozel karakterli display_name XML'i bozuyor veya kacis degeri degistiriyor"

# Restore'u burada da acikca yapiyoruz (basarili yolda trap'i beklemeden);
# trap yine de EXIT'te calisip bunu idempotent olarak tekrar eder.
restore_display_name
DISPLAY_NAME_DIRTY=0

# FreeSWITCH tarafindan gorunurluk — mod_xml_curl gercekten xmlapi'ye
# ulasiyor mu, gercek FreeSWITCH sureci uzerinden dogrula.
#
# NOT: "xml_locate directory domain tenant1.voip.local" (brief'teki komut)
# calismiyor: fs_cli'nin gercek xml_locate imzasi
# "xml_locate <section> <tag> <tag_attr_name> <tag_attr_val>" — uc
# argumanla "-ERR bad args" doner. Dogru sozdizimiyle bile
# ("xml_locate directory domain name tenant1.voip.local") bu, SADECE
# domain'e gore bir arama yapar; "user" parametresi hic gonderilmez ve
# xmlapi'nin directory() fonksiyonu user'siz istekleri BILEREK bulunamadi
# sayar (bkz. app.py). Bu yuzden domain-only xml_locate ampirik olarak her
# zaman "can't find anything" doner — dogru yapilandirmada bile — yanlis
# negatif verirdi. Onun yerine find_user_xml kullaniyoruz: bu, mod_sofia'nin
# SIP REGISTER/INVITE sirasinda gercekten cagirdigi ayni user+domain arama
# yolunu izler ve xmlapi'den gelen HAM (ayristirilmis) directory belgesini
# aynen basar.
FOUND=$($FSCLI "find_user_xml id alice tenant1.voip.local")
echo "$FOUND" | grep -q 'id="alice"' \
  || fail "FreeSWITCH xml_curl uzerinden alice'i goremiyor (find_user_xml)"
echo "$FOUND" | grep -q 'name="tenant_id" value="1"' \
  || fail "FreeSWITCH tarafinda tenant_id gorunmuyor (find_user_xml)"
echo "$FOUND" | grep -q 'name="password"' \
  && fail "FreeSWITCH tarafinda hala cleartext sifre gorunuyor (find_user_xml)"

echo "OK: verify-07-xmlcurl"
