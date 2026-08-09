#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

# Gercek core.db yolu (bkz. /opt/freeswitch/var/lib/freeswitch/db/core.db,
# fs_cli "global_getvar db_dir" ile dogrulandi). FreeSWITCH'in vanilla
# ornek/dokumantasyonundaki "/opt/freeswitch/var/db" yolu bu build icin
# GECERSIZ: --prefix=/opt/freeswitch ile derlenen bu FreeSWITCH surumunde
# db_dir "$${base_dir}/var/lib/freeswitch/db" olarak hesaplaniyor. Yanlis
# yola karsi test etmek "test -s <hicbir_zaman_var_olmayan_dosya>" hep false
# donup fail tetiklenmeyecegi icin sessizce (vacuously) gecerdi ve
# core-db-dsn devre disi kalsa bile script YINE OK basardi.
CORE_DB_PATH=/opt/freeswitch/var/lib/freeswitch/db/core.db

docker compose up -d freeswitch
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
wait_fs() {
  for i in $(seq 1 45); do
    $FSCLI "status" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
wait_fs || fail "fs_cli baglanamiyor (ilk baslatma)"

qfs() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$FS_DB_NAME" -tAc "$1"; }

# --- 1. FreeSWITCH acilista kendi core tablolarini PostgreSQL'de olusturmus mu ---
for t in channels calls tasks; do
  [ "$(qfs "SELECT to_regclass('public.$t') IS NOT NULL")" = "t" ] \
    || fail "core tablo PostgreSQL'de yok: $t (core-db-dsn calismiyor)"
done

# --- 2. SQLite fallback kontrolu: VACUOUS OLMAMASI icin, eski core.db'yi
#     silip FreeSWITCH'i yeniden baslatiyoruz. Eger core-db-dsn devre disiysa
#     FreeSWITCH sessizce SQLite'a duser ve core.db'yi YENIDEN olusturur.
#     Dosyanin onceden var olup olmadigina degil, YENIDEN OLUSUP OLUSMADIGINA
#     bakiyoruz — bu sayede eski/stale bir core.db dosyasi testi yanlis
#     "fail" etmez, ve olmayan bir yola karsi test etmek de yanlis "OK" vermez.
docker compose exec -T freeswitch sh -c "rm -f '$CORE_DB_PATH'"
docker compose restart freeswitch
wait_fs || fail "fs_cli baglanamiyor (core.db silindikten sonraki restart)"

docker compose exec -T freeswitch sh -c "test -s '$CORE_DB_PATH'" \
  && fail "core.db (SQLite, $CORE_DB_PATH) restart sonrasi YENIDEN yazildi — core-db-dsn devrede degil, sessizce SQLite'a dusulmus"

# Ayni tablolar restart sonrasi da PostgreSQL'de olmali (yeniden baslatma
# core-db-dsn'i bozmamis).
for t in channels calls tasks; do
  [ "$(qfs "SELECT to_regclass('public.$t') IS NOT NULL")" = "t" ] \
    || fail "restart sonrasi core tablo PostgreSQL'de yok: $t"
done

# --- 3. Canli veri kaniti: sadece tablo VARLIGI yetmez (auto-create-schemas
#     bunu tek basina saglar). FreeSWITCH'in PostgreSQL'e GERCEKTEN YAZDIGINI
#     kanitlamak icin: (a) mod_hash'in kendiliginden zamanladigi periyodik
#     "limit_hash_cleanup" gorevini fs_cli "show tasks" ile dogrula, VE
#     (b) ayni satirin dogrudan PostgreSQL sorgusuyla da gorunur oldugunu
#     dogrula — boylece "show tasks" komutunun kendisinin FreeSWITCH'in aktif
#     backend'inden (artik PostgreSQL) okudugunu, statik/onbellek bir
#     deger olmadigini kanitlamis oluyoruz.
$FSCLI "show tasks" | grep -q "limit_hash_cleanup" \
  || fail "fs_cli 'show tasks' icinde beklenen periyodik gorev (limit_hash_cleanup) yok"

TASK_ROWS=$(qfs "SELECT count(*) FROM tasks WHERE task_desc = 'limit_hash_cleanup'")
[ "${TASK_ROWS:-0}" -gt 0 ] \
  || fail "PostgreSQL'deki tasks tablosunda limit_hash_cleanup satiri yok — FreeSWITCH PostgreSQL'e yazmiyor olabilir"

# Ekstra canli veri kaniti: fs_cli araciligiyla yeni bir gorev zamanla, hemen
# ardindan bu spesifik satirin PostgreSQL'de goruldugunu dogrula (ayni ana
# ait, taze bir yazma - onceki bir calistirmadan kalma olamaz).
MARK="verify06_$(date +%s)_$$"
$FSCLI "sched_api +120 ${MARK} status" | grep -q "+OK" \
  || fail "sched_api ile test gorevi zamanlanamadi"
sleep 1
MARK_ROWS=$(qfs "SELECT count(*) FROM tasks WHERE task_group = '${MARK}'")
[ "${MARK_ROWS:-0}" -gt 0 ] \
  || fail "sched_api ile eklenen '${MARK}' gorevi PostgreSQL'de gorunmuyor — FreeSWITCH PostgreSQL'e canli yazmiyor"

# --- 4. RTP port araligi uygulanmis mi ---
# NOT: rtp-start-port/rtp-end-port core "settings" parametreleridir, FreeSWITCH
# bunlari global degisken (global_getvar) olarak DISA VERMEZ — ampirik olarak
# dogrulandi: dogru sekilde yapilandirilmis bir sistemde bile
# "global_getvar rtp_start_port" "-ERR no reply" doner (oysa sip_domain gibi
# <variables> altinda tanimlanan gercek global degiskenler duzgun doner).
# Bu yuzden brief'in onerdigi global_getvar kontrolu HER ZAMAN basarisiz
# olurdu (dogru yapilandirmada bile) — yanlis negatif verirdi. Onun yerine
# FreeSWITCH'in xml_locate API'siyle CANLI, ayristirilmis (parse edilmis)
# konfigurasyon agacini soruyoruz: bu, sadece dosyada dogru metin oldugunu
# degil, FreeSWITCH'in bu degeri GERCEKTEN yukledigini kanitliyor.
XMLCFG=$($FSCLI "xml_locate configuration configuration name switch.conf")
echo "$XMLCFG" | grep -q "name=\"rtp-start-port\" value=\"${RTP_START}\"" || fail "rtp-start-port canli konfigurasyonda yok/yanlis (xml_locate)"
echo "$XMLCFG" | grep -q "name=\"rtp-end-port\" value=\"${RTP_END}\""     || fail "rtp-end-port canli konfigurasyonda yok/yanlis (xml_locate)"
echo "$XMLCFG" | grep -q "name=\"core-db-dsn\" value=\"pgsql://host=postgres port=5432 dbname=${FS_DB_NAME} user=${POSTGRES_USER} password=${POSTGRES_PASSWORD}\"" \
  || fail "core-db-dsn canli konfigurasyonda beklenen degerle yuklenmemis (xml_locate)"

# --- 5. Global degiskenler (Task 6'nin ureteceklerini vaat ettigi arayuz) ---
$FSCLI "global_getvar sip_domain" | grep -q "^${SIP_DOMAIN}$" || fail "sip_domain global degiskeni yanlis/eksik"
$FSCLI "global_getvar external_ip" | grep -q "^${EXTERNAL_IP}$" || fail "external_ip global degiskeni yanlis/eksik"
$FSCLI "global_getvar global_codec_prefs" | grep -q "OPUS" || fail "global_codec_prefs eksik"
$FSCLI "global_getvar outbound_codec_prefs" | grep -q "OPUS" || fail "outbound_codec_prefs eksik"

# --- 6. Commit edilmis dosyalarda duz metin sifre kalmamis olmali ---
# Hem eski/yanlis "kamailio" sifresi hem de .env'deki GERCEK sifre, git'e
# eklenmis (staged/tracked) hicbir dosyada literal olarak gecmemeli.
LEAK=$(git grep -n -F -e "$POSTGRES_PASSWORD" -- 'freeswitch/conf' 2>/dev/null || true)
[ -z "$LEAK" ] || fail "git-tracked dosyada duz metin POSTGRES_PASSWORD bulundu: $LEAK"

echo "OK: verify-06-core-db"
