#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a

fail() { echo "FAIL: $*" >&2; exit 1; }
q()    { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$1" -tAc "$2"; }

docker compose up -d postgres
for i in $(seq 1 30); do
  docker compose exec -T postgres pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1 && break
  sleep 2
done

for t in tenants subscriber location dialplan acc missed_calls cdr dispatcher version; do
  [ "$(q "$POSTGRES_DB" "SELECT to_regclass('public.$t') IS NOT NULL")" = "t" ] \
    || fail "tablo yok: $t"
done

for v in fs_directory fs_dialplan; do
  [ "$(q "$POSTGRES_DB" "SELECT count(*) FROM pg_views WHERE viewname='$v'")" = "1" ] \
    || fail "view yok: $v"
done

# Kamailio'nun bekledigi tablo surumleri
while read -r tbl ver; do
  got=$(q "$POSTGRES_DB" "SELECT table_version FROM version WHERE table_name='$tbl'")
  [ "$got" = "$ver" ] || fail "$tbl surumu $got, beklenen $ver"
done <<'EOF'
subscriber 7
location 9
acc 5
missed_calls 4
dispatcher 4
EOF

[ "$(q "$POSTGRES_DB" "SELECT count(*) FROM tenants WHERE domain='tenant1.voip.local'")" = "1" ] \
  || fail "tenant1 seed edilmemis"
[ "$(q "$POSTGRES_DB" "SELECT count(*) FROM subscriber WHERE username IN ('alice','bob')")" = "2" ] \
  || fail "alice/bob seed edilmemis"
[ "$(q "$POSTGRES_DB" "SELECT count(*) FROM subscriber WHERE ha1 <> '' AND ha1b <> ''")" = "2" ] \
  || fail "ha1/ha1b bos"
[ "$(q "$POSTGRES_DB" "SELECT count(*) FROM dispatcher WHERE setid=1")" -ge 1 ] \
  || fail "dispatcher satiri yok"

# fs_directory tenant_id dondurmeli (CDR icin)
q "$POSTGRES_DB" "SELECT tenant_id FROM fs_directory WHERE \"user\"='alice'" | grep -qE '^[0-9]+$' \
  || fail "fs_directory tenant_id dondurmuyor"

# Ikinci veritabani
[ "$(q postgres "SELECT count(*) FROM pg_database WHERE datname='$FS_DB_NAME'")" = "1" ] \
  || fail "$FS_DB_NAME veritabani yok"

echo "OK: verify-02-database"
