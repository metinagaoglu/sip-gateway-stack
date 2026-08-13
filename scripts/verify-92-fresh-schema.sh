#!/usr/bin/env bash
# db/init/ scriptlerinin SIFIRDAN kurulumda calistigini dogrular.
#
# NEDEN AYRI BIR TEST: `docker-entrypoint-initdb.d` scriptleri YALNIZCA bos bir
# veri dizininde calisir. Yani calisan veritabani, `01-schema.sql`'e sonradan
# yapilan degisiklikleri HIC gormez. Bu oturumda tam bu durum olustu:
# `answer_epoch` kolonu semaya eklendi ama mevcut veritabanina elle
# `ALTER TABLE` ile geldi. Sema dosyasi bozuk olsa bile her sey calisir
# gorunurdu; sorun ancak yeni bir makinede kurulum yapilinca ortaya cikardi.
#
# Bu script YIKICI DEGIL: `docker compose down -v` yapmak yerine GECICI bir
# veritabani olusturup init scriptlerini orada kosar ve sonra dusurur.
# Mevcut veriye dokunmaz.
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

TESTDB="fresh_schema_check"
PSQL_ADMIN() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres -tAc "$1"; }
PSQL_TEST()  { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$TESTDB" -tAc "$1"; }

cleanup() {
  PSQL_ADMIN "DROP DATABASE IF EXISTS ${TESTDB};" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose up -d postgres >/dev/null 2>&1
for i in $(seq 1 30); do PSQL_ADMIN "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
PSQL_ADMIN "SELECT 1" >/dev/null 2>&1 || fail "PostgreSQL'e baglanilamadi"

echo "--- 1. temiz veritabani olustur ---"
PSQL_ADMIN "DROP DATABASE IF EXISTS ${TESTDB};" >/dev/null
PSQL_ADMIN "CREATE DATABASE ${TESTDB} OWNER ${POSTGRES_USER};" >/dev/null

echo "--- 2. 01-schema.sql HATASIZ calisiyor mu ---"
# ON_ERROR_STOP=1 sart: onsuz psql hatali ifadeleri atlayip 0 ile cikar ve
# bozuk bir sema "basarili" gorunur.
OUT=$(docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TESTDB" \
        -f /docker-entrypoint-initdb.d/01-schema.sql 2>&1) \
  || { echo "$OUT" | tail -20; fail "01-schema.sql sifirdan kurulumda HATA verdi"; }
echo "$OUT" | grep -qiE "^ERROR|^FATAL" \
  && { echo "$OUT" | grep -iE "^ERROR|^FATAL" | head -5; fail "01-schema.sql ciktisinda ERROR var"; }

echo "--- 3. 02-seed.sql HATASIZ calisiyor mu ---"
OUT=$(docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TESTDB" \
        -f /docker-entrypoint-initdb.d/02-seed.sql 2>&1) \
  || { echo "$OUT" | tail -20; fail "02-seed.sql sifirdan kurulumda HATA verdi"; }

echo "--- 4. Kamailio'nun bekledigi tablolar semadan geldi mi ---"
for t in subscriber location dispatcher version tenants cdr; do
  [ "$(PSQL_TEST "SELECT to_regclass('public.$t') IS NOT NULL")" = "t" ] \
    || fail "$t tablosu 01-schema.sql'den GELMIYOR"
done

echo "--- 5. answer_epoch SEMADAN geliyor mu (elle ALTER TABLE ile degil) ---"
# Bu kontrolun tamami bu testin var olma sebebi. Calisan veritabaninda kolon
# ALTER TABLE ile eklendi; sema dosyasina da eklenmemis olsaydi yeni kurulumda
# mod_cdr_pg_csv'nin INSERT'i patlar ve CDR'lar sessizce diske duserdi.
[ "$(PSQL_TEST "SELECT count(*) FROM information_schema.columns WHERE table_name='cdr' AND column_name='answer_epoch'")" = "1" ] \
  || fail "answer_epoch kolonu 01-schema.sql'de YOK — sifirdan kurulumda CDR yazilamaz (Task 10)"
[ "$(PSQL_TEST "SELECT data_type FROM information_schema.columns WHERE table_name='cdr' AND column_name='answer_epoch'")" = "bigint" ] \
  || fail "answer_epoch bigint degil"

echo "--- 6. seed verisi geldi ve ha1 dogru realm ile hesaplandi mi ---"
[ "$(PSQL_TEST "SELECT count(*) FROM tenants")" -ge 1 ] || fail "seed'de kiraci yok"
for pair in "alice:alice123" "bob:bob123"; do
  U="${pair%%:*}"; P="${pair##*:}"
  DOM=$(PSQL_TEST "SELECT domain FROM subscriber WHERE username='$U'")
  [ -n "$DOM" ] || fail "$U abonesi seed'den gelmedi"
  EXPECT=$(printf '%s:%s:%s' "$U" "$DOM" "$P" | md5 -q 2>/dev/null || printf '%s:%s:%s' "$U" "$DOM" "$P" | md5sum | cut -d' ' -f1)
  [ "$EXPECT" = "$(PSQL_TEST "SELECT ha1 FROM subscriber WHERE username='$U'")" ] \
    || fail "$U icin seed ha1'i md5($U:$DOM:$P) ile uyusmuyor — yeni kurulumda REGISTER sonsuz 401 doner"
done
echo "  seed: $(PSQL_TEST "SELECT count(*) FROM subscriber") abone, ha1'ler dogru"

echo "--- 7. dispatcher hedefi semadan/seed'den geliyor mu ---"
[ "$(PSQL_TEST "SELECT count(*) FROM dispatcher WHERE destination LIKE '%freeswitch%'")" -ge 1 ] \
  || fail "dispatcher hedefi seed'den gelmiyor — yeni kurulumda cagrilar 503 alir"

echo "--- 8. 03-freeswitch-db.sh ikinci veritabanini olusturuyor mu ---"
# Script CREATE DATABASE yapar; onu gercekten kosmak calisan ${FS_DB_NAME} ile
# catisir, o yuzden ICERIGINI dogruluyoruz: dogru degiskeni kullaniyor mu ve
# ON_ERROR_STOP ile mi calisiyor.
grep -q 'CREATE DATABASE ${FS_DB_NAME}' db/init/03-freeswitch-db.sh \
  || fail "03-freeswitch-db.sh \${FS_DB_NAME} degiskenini kullanmiyor"
grep -q 'ON_ERROR_STOP=1' db/init/03-freeswitch-db.sh \
  || fail "03-freeswitch-db.sh ON_ERROR_STOP=1 kullanmiyor — sessiz basarisizlik riski"
grep -q 'FS_DB_NAME' docker-compose.yml \
  || fail "FS_DB_NAME compose'da postgres servisine verilmiyor — init scripti bos ad kullanir"

echo "OK: verify-92-fresh-schema"
echo "NOT: Bu script SIFIRDAN kurulumu gecici bir veritabaninda dogrular;"
echo "     mevcut veriye DOKUNMAZ. Kanitlanan: init scriptleri hatasiz kosuyor,"
echo "     Kamailio tablolari + cdr.answer_epoch semadan geliyor, seed ha1'leri"
echo "     dogru realm ile hesaplanmis, dispatcher hedefi mevcut."
