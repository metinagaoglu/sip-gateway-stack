#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }

docker compose up -d
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done
$FSCLI "status" >/dev/null 2>&1 || fail "FreeSWITCH ESL'e yanit vermiyor"

echo "--- 1. mod_cdr_pg_csv yuklu mu ---"
$FSCLI "show modules" | grep -q "mod_cdr_pg_csv" \
  || fail "mod_cdr_pg_csv yuklu degil (modules.conf.xml)"

echo "--- 2. answer_epoch kolonu var mi ---"
# Cevaplanmayan cagrida ${answer_stamp} BOS STRING olur ve TIMESTAMP kolonuna
# '' yazilamaz -> INSERT patlar, kayit diske duser. ${answer_epoch} her zaman
# sayidir (cevaplanmadiysa 0), o yuzden sema answer_stamp yerine onu kullanir.
[ "$(q "SELECT count(*) FROM information_schema.columns WHERE table_name='cdr' AND column_name='answer_epoch'")" = "1" ] \
  || fail "cdr tablosunda answer_epoch kolonu yok (db/init/01-schema.sql + ALTER TABLE migrasyonu)"

echo "--- 3. canli konfigurasyon: db-info cozulmus ve schema yuklu mu ---"
# Sadece dosyada dogru metin olmasi yetmez; FreeSWITCH'in GERCEKTEN yukledigi
# agaci okuyoruz. `${dsn(...)}` gibi cozulmemis bir deger burada yakalanir.
CDR_XML=$($FSCLI "xml_locate configuration configuration name cdr_pg_csv.conf")
echo "$CDR_XML" | grep -q "dbname=${POSTGRES_DB}" \
  || fail "db-info canli konfigurasyonda cozulmemis (dbname=${POSTGRES_DB} yok)"
echo "$CDR_XML" | grep -q 'name="db-table" value="cdr"' \
  || fail "db-table canli konfigurasyonda 'cdr' degil"
echo "$CDR_XML" | grep -q "<schema>" \
  || fail "<schema> blogu canli konfigurasyonda YOK — modul alan listesi olusturamaz ve CS_REPORTING'de SIGSEGV verir (bkz. progress.md)"
echo "$CDR_XML" | grep -q 'name="answer_epoch"' \
  || fail "semada answer_epoch alani yok"
# Gecersiz parametre uyarisi: bu modulun binary'sinde SADECE db-info,
# db-table, rotate-on-hup, legs, debug var. log-dir/table/log-b-leg/
# filter-zerobillsec/write-cdr-on-exit YOK — yazilirsa sessizce yok sayilir
# ve "yapilandirdim" yanilgisi yaratir.
echo "$CDR_XML" | grep -qE 'name="(log-dir|table|log-b-leg|filter-zerobillsec|write-cdr-on-exit)"' \
  && fail "konfigurasyonda mod_cdr_pg_csv'de VAR OLMAYAN bir parametre var (sessizce yok sayilir) — modul binary'sinde yalnizca db-info/db-table/rotate-on-hup/legs/debug bulunuyor"

echo "--- 4. GERCEK cagri ile CDR uretimi ---"
BEFORE=$(q "SELECT count(*) FROM cdr")
RC_BEFORE=$(docker inspect voip-freeswitch --format '{{.RestartCount}}')

# NOT: plan burada `originate loopback/9998/default` kullaniyordu; mod_loopback
# BILEREK yuklenmiyor (Task 8) ve zaten sentetik. Bunun yerine gercek bir SIP
# cagrisi kuruyoruz — CDR'in uretim yolunda ne yazildigini test eder.
python3 tools/sip-call-probe.py \
  --proxy "${EXTERNAL_IP}:5060" --domain "tenant1.voip.local" \
  --user alice --password alice123 --dest 9999 \
  --hold 2 --rtp-packets 40 >/dev/null 2>&1 \
  || fail "test cagrisi kurulamadi — once verify-08'i calistirin"

# CDR, CS_REPORTING asamasinda yazilir; cagri kapandiktan sonra kisa gecikme.
for i in $(seq 1 20); do
  AFTER=$(q "SELECT count(*) FROM cdr")
  [ "$AFTER" -gt "$BEFORE" ] && break
  sleep 1
done
[ "${AFTER:-0}" -gt "$BEFORE" ] \
  || fail "CDR satiri olusmadi ($BEFORE -> ${AFTER:-0}) — 'docker compose logs freeswitch | grep -i cdr' ile INSERT hatasina bakin"
echo "  CDR satiri yazildi ($BEFORE -> $AFTER)"

echo "--- 5. FreeSWITCH cagriyi raporlarken SAG kaldi mi ---"
# mod_cdr_pg_csv'nin gecmisteki SIGSEGV'si tam bu asamada oluyordu.
[ "$(docker inspect voip-freeswitch --format '{{.RestartCount}}')" = "$RC_BEFORE" ] \
  || fail "FreeSWITCH CDR yazarken COKTU — semayi kontrol edin (bkz. progress.md, my_on_reporting/cdr_field)"
$FSCLI "status" >/dev/null 2>&1 || fail "FreeSWITCH CDR sonrasi ESL'e yanit vermiyor"

echo "--- 6. zorunlu alanlar dolu mu ---"
[ "$(q "SELECT count(*) FROM cdr WHERE uuid IS NULL")" = "0" ] \
  || fail "uuid bos CDR var"
[ "$(q "SELECT count(*) FROM cdr WHERE hangup_cause IS NULL OR hangup_cause=''")" = "0" ] \
  || fail "hangup_cause bos CDR var"
[ "$(q "SELECT count(*) FROM cdr WHERE tenant_id IS NULL")" = "0" ] \
  || fail "tenant_id bos CDR var — dialplan'daki tenant-default extension'i calismiyor"

echo "--- 7. son cagrinin alanlari anlamli mi ---"
# Satir sayisinin artmasi yetmez: alanlar GERCEKTEN dolduruldu mu?
LAST=$(q "SELECT destination_number||'|'||coalesce(caller_id_number,'')||'|'||context||'|'||coalesce(read_codec,'')||'|'||duration FROM cdr ORDER BY id DESC LIMIT 1")
echo "  son CDR: $LAST"
echo "$LAST" | grep -q "^9999|" \
  || fail "son CDR'in destination_number'i 9999 degil ($LAST)"
echo "$LAST" | grep -q "|alice|" \
  || fail "son CDR'in caller_id_number'i alice degil ($LAST)"
echo "$LAST" | grep -q "|default|" \
  || fail "son CDR'in context'i default degil ($LAST)"
[ "$(q "SELECT count(*) FROM cdr WHERE start_stamp IS NULL OR end_stamp IS NULL")" = "0" ] \
  || fail "start_stamp/end_stamp bos CDR var"

# --- DIALOG ICI BYE REGRESYONU (en sinsi hatalardan biri) ---
# Cagri BYE ile kapandiysa hangup_cause NORMAL_CLEARING olur ve duration
# gercek konusma suresine esittir. Dialog ici ACK/BYE yerine ulasmadiginda
# ise FreeSWITCH ACK'i hic gormez, 200 OK'i retransmit eder ve cagri 32 sn
# sonra zaman asimiyla duser: duration=32, hangup_cause=NORMAL_UNSPECIFIED.
# Bu, SIP tarafinda "OK" gibi gorunuyordu (probe, FreeSWITCH'in retransmit
# ettigi 200 OK'i BYE yaniti saniyordu) ve ses de aktigi icin (RTP ayri yol)
# hicbir test yakalamiyordu. CDR bunu ELE VERIR — o yuzden kontrol burada.
# Sebepler ve cozum: kamailio.cfg (has_totag dali, uri == myself -> $du) ve
# freeswitch/conf/sip_profiles/internal.xml.tmpl (ext-sip-ip cakismasi).
LAST_CAUSE=$(q "SELECT hangup_cause FROM cdr ORDER BY id DESC LIMIT 1")
LAST_DUR=$(q "SELECT duration FROM cdr ORDER BY id DESC LIMIT 1")
[ "$LAST_CAUSE" = "NORMAL_CLEARING" ] \
  || fail "son CDR'in hangup_cause'u NORMAL_CLEARING degil ($LAST_CAUSE) — BYE FreeSWITCH'e ULASMIYOR; cagri zaman asimiyla dusuyor (dialog ici yonlendirme bozuk)"
[ "$LAST_DUR" -lt 30 ] \
  || fail "son CDR'in duration'i ${LAST_DUR}s — BYE ulasmadi, cagri zaman asimina kadar acik kaldi (beklenen: probe --hold suresi kadar)"
echo "  BYE ile temiz kapanma dogrulandi (${LAST_CAUSE}, ${LAST_DUR}s)"

echo "--- 8. PostgreSQL'e yazilamayip diske dusen CDR var mi ---"
# Basarisiz INSERT'ler bu dizine CSV olarak birikir. Sema uyusmazliginin
# en sessiz belirtisi budur: satir sayisi artmaz ama hata da gorunmez.
LEFT=$(docker compose exec -T freeswitch sh -c \
  'ls /opt/freeswitch/var/log/freeswitch/cdr-pg-csv/*.csv 2>/dev/null | wc -l' | tr -d ' \r')
[ "$LEFT" = "0" ] \
  || fail "$LEFT adet CDR PostgreSQL'e yazilamayip diske dustu — sema cdr tablosuyla uyusmuyor"

echo "OK: verify-10-cdr"
echo "NOT: Bu script KANITLAR:"
echo "     - mod_cdr_pg_csv yuklu ve CANLI konfigurasyonunda cozulmus db-info + <schema> var,"
echo "     - VAR OLMAYAN parametre yazilmamis (sessizce yok sayilanlar),"
echo "     - GERCEK bir SIP cagrisi cdr tablosuna satir yaziyor,"
echo "     - alanlar anlamli (9999/alice/default/zaman damgalari/tenant_id),"
echo "     - FreeSWITCH raporlama asamasindan sag cikiyor (eski SIGSEGV),"
echo "     - hicbir CDR diske dusmuyor (sema uyusmazligi yok)."
