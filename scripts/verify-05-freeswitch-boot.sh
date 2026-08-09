#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose build freeswitch || fail "freeswitch image build edilemedi"
docker compose up -d freeswitch

FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 45); do
  $FSCLI "status" >/dev/null 2>&1 && break
  sleep 2
done

$FSCLI "status" >/dev/null 2>&1 \
  || fail "fs_cli baglanamiyor — event socket bind olmamis olabilir"

$FSCLI "version" | grep -q "1\.10\.12" || fail "beklenmeyen FreeSWITCH surumu"

LOG=$(docker compose logs freeswitch 2>&1)
echo "$LOG" | grep -q "Cannot get information about IP address ::" \
  && fail "event socket hala IPv6'ya bind olmaya calisiyor"
echo "$LOG" | grep -qE "Error Loading module .*(mod_verto|mod_signalwire)" \
  && fail "mod_verto/mod_signalwire hala yuklenmeye calisiliyor"

for m in mod_pgsql mod_xml_curl mod_cdr_pg_csv mod_lua mod_sofia mod_dptools; do
  $FSCLI "module_exists $m" | grep -q true || fail "modul yuklu degil: $m"
done

echo "OK: verify-05-freeswitch-boot"
