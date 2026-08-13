#!/usr/bin/env bash
# Veritabani butunlugu: sema, kisitlar, seed dogrulugu, veri tutarliligi.
# Yikici DEGIL, salt okunur (tek istisna: gecici bir FK ihlali denemesi ki o da
# geri aliniyor).
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }
q()  { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }
qf() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$FS_DB_NAME"   -tAc "$1"; }

docker compose up -d postgres >/dev/null 2>&1
for i in $(seq 1 30); do q "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
q "SELECT 1" >/dev/null 2>&1 || fail "PostgreSQL'e baglanilamadi"

echo "--- 1. iki ayri veritabani var mi ---"
# Mimari ayrim: kamailio DB = abone/kayit/yonlendirme + raporlama (cdr);
# freeswitch DB = FreeSWITCH'in OPERASYONEL verisi (channels, limit_data...).
[ "$(q "SELECT count(*) FROM pg_database WHERE datname='${POSTGRES_DB}'")" = "1" ] \
  || fail "${POSTGRES_DB} veritabani yok"
[ "$(q "SELECT count(*) FROM pg_database WHERE datname='${FS_DB_NAME}'")" = "1" ] \
  || fail "${FS_DB_NAME} veritabani yok — FreeSWITCH core DB ayrimi bozulmus"

echo "--- 2. Kamailio'nun bekledigi tablolar ---"
for t in subscriber location dispatcher version tenants cdr; do
  [ "$(q "SELECT to_regclass('public.$t') IS NOT NULL")" = "t" ] \
    || fail "$t tablosu ${POSTGRES_DB} icinde yok"
done

echo "--- 3. cdr semasi mod_cdr_pg_csv sablonuyla BIREBIR uyusuyor mu ---"
# Sema ile <schema> blogu ayri duserse mod_cdr_pg_csv INSERT'i patlar ve
# kayitlar sessizce diske duser (Task 10). O yuzden alanlari tek tek
# dogruluyoruz — ozellikle answer_epoch, cunku o kolon plan sonradan eklendi
# ve MEVCUT veritabanina ALTER TABLE ile geldi. Sifirdan kurulumda
# 01-schema.sql'den gelmek ZORUNDA.
for c in tenant_id uuid caller_id_name caller_id_number destination_number \
         context start_stamp end_stamp answer_epoch duration billsec \
         hangup_cause sip_hangup_disposition read_codec write_codec \
         remote_media_ip; do
  [ "$(q "SELECT count(*) FROM information_schema.columns WHERE table_name='cdr' AND column_name='$c'")" = "1" ] \
    || fail "cdr tablosunda '$c' kolonu yok — mod_cdr_pg_csv <schema> blogu ile uyusmuyor (db/init/01-schema.sql)"
done
# answer_stamp KALMALI (geriye donuk uyum) ama sema onu KULLANMAMALI.
[ "$(q "SELECT count(*) FROM information_schema.columns WHERE table_name='cdr' AND column_name='answer_stamp'")" = "1" ] \
  || fail "cdr.answer_stamp kolonu kaybolmus"

echo "--- 4. tenant FK'si GERCEKTEN zorlaniyor mu ---"
# Kisitin varligini information_schema'dan okumak yetmez; ihlali fiilen
# denemek gerekir. Var olmayan bir tenant_id ile INSERT REDDEDILMELI.
if q "INSERT INTO cdr (tenant_id, uuid, destination_number) VALUES (999999, gen_random_uuid(), 'fk-test')" >/dev/null 2>&1; then
  q "DELETE FROM cdr WHERE destination_number='fk-test'" >/dev/null 2>&1 || true
  fail "cdr.tenant_id FK'si zorlanmiyor — var olmayan tenant ile CDR yazilabildi"
fi
echo "  var olmayan tenant ile CDR reddedildi"

echo "--- 5. index'ler yerinde mi (CDR sorgulari tablo taramasina dusmesin) ---"
for i in cdr_uuid_idx cdr_tenant_idx cdr_start_stamp_idx; do
  [ "$(q "SELECT count(*) FROM pg_indexes WHERE tablename='cdr' AND indexname='$i'")" = "1" ] \
    || fail "$i index'i yok"
done

echo "--- 6. seed dogrulugu: ha1 GERCEKTEN realm ile hesaplanmis mi ---"
# ha1 = md5(username:domain:password). Realm yanlis hesaplanmissa REGISTER
# sonsuz 401 dongusune girer ve sebebi cok gec anlasilir. Degeri burada
# BAGIMSIZ olarak yeniden hesaplayip karsilastiriyoruz.
for pair in "alice:alice123" "bob:bob123"; do
  U="${pair%%:*}"; P="${pair##*:}"
  DOM=$(q "SELECT domain FROM subscriber WHERE username='$U'")
  [ -n "$DOM" ] || fail "$U abonesi seed'de yok"
  EXPECT=$(printf '%s:%s:%s' "$U" "$DOM" "$P" | md5 -q 2>/dev/null || printf '%s:%s:%s' "$U" "$DOM" "$P" | md5sum | cut -d' ' -f1)
  ACTUAL=$(q "SELECT ha1 FROM subscriber WHERE username='$U'")
  [ "$EXPECT" = "$ACTUAL" ] \
    || fail "$U icin ha1 yanlis. beklenen=md5($U:$DOM:$P)=$EXPECT ama veritabaninda=$ACTUAL — REGISTER sonsuz 401 doner"
  [ "$(q "SELECT enabled FROM subscriber WHERE username='$U'")" = "t" ] \
    || fail "$U abonesi enabled=false"
done
echo "  alice ve bob icin ha1 dogru realm ile hesaplanmis"

echo "--- 7. dispatcher hedefi FreeSWITCH'i gosteriyor mu ---"
[ "$(q "SELECT count(*) FROM dispatcher WHERE destination LIKE '%freeswitch%'")" -ge 1 ] \
  || fail "dispatcher tablosunda FreeSWITCH hedefi yok"

echo "--- 8. FreeSWITCH core DB tablolari PostgreSQL'de mi (SQLite'a dusmemis) ---"
for t in channels calls registrations tasks; do
  [ "$(qf "SELECT to_regclass('public.$t') IS NOT NULL")" = "t" ] \
    || fail "$t tablosu ${FS_DB_NAME} icinde yok — core DB SQLite'a dusmus olabilir"
done

echo "--- 9. CDR verisi ic tutarli mi ---"
# Bu kontroller gecmis cagrilar hakkinda: mantiksal olarak imkansiz satir
# olmamali. Bos tabloda da gecer (henuz cagri yapilmamis olabilir).
[ "$(q "SELECT count(*) FROM cdr WHERE end_stamp < start_stamp")" = "0" ] \
  || fail "end_stamp < start_stamp olan CDR var"
[ "$(q "SELECT count(*) FROM cdr WHERE billsec > duration")" = "0" ] \
  || fail "billsec > duration olan CDR var (faturalama hatasi)"
[ "$(q "SELECT count(*) FROM cdr WHERE duration < 0 OR billsec < 0")" = "0" ] \
  || fail "negatif duration/billsec olan CDR var"
CDR_N=$(q "SELECT count(*) FROM cdr")
echo "  ${CDR_N} CDR satiri tutarli"

echo "OK: verify-90-db-integrity"
