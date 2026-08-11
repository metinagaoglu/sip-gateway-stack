#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }
q()  { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }
qf() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$FS_DB_NAME"   -tAc "$1"; }

# --- restore guard: adim 6 alice'in max_calls degerini 1'e dusurur. Script
#     NEREDE basarisiz olursa olsun (assertion, ctrl-c, beklenmedik hata)
#     EXIT trap'i orijinal degeri geri yazar; sonraki task bozuk seed
#     devralmasin. (verify-07'deki ayni desen.)
MAXCALLS_DIRTY=0
restore_maxcalls() {
  if [ "$MAXCALLS_DIRTY" = "1" ]; then
    q "UPDATE subscriber SET max_calls=2 WHERE username='alice';" >/dev/null 2>&1 || true
  fi
  [ -n "${UAS_PID:-}" ] && kill "$UAS_PID" 2>/dev/null || true
  rm -f "${UAS_LOG:-}" "${P1_LOG:-}" "${P2_LOG:-}"
}
trap restore_maxcalls EXIT

docker compose up -d
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done
$FSCLI "status" >/dev/null 2>&1 || fail "FreeSWITCH ESL'e yanit vermiyor"

echo "--- 1. mod_lua ve mod_db yuklu mu ---"
$FSCLI "module_exists mod_lua" | grep -q true || fail "mod_lua yuklu degil"
# mod_db PLANDA ATLANMISTI. `limit`in `db` ARKA UCU buradan gelir; mod_hash
# yalnizca bellek-ici `limit_hash` saglar. mod_db yuklu olmazsa dialplan'daki
# `limit db ...` satirinin arka ucu bulunmaz ve sinir kalici olarak tutulmaz.
$FSCLI "module_exists mod_db" | grep -q true \
  || fail "mod_db yuklu degil — 'db' limit arka ucu olmaz (modules.conf.xml)"
# DIKKAT iki AYRI sey var ve ikisi de gerekli:
#  - `limit` UYGULAMASI mod_dptools'tan gelir  -> `show application`
#  - `db` ARKA UCU mod_db'den gelir            -> `show modules` (limit,db,mod_db)
# Komut `show application` (TEKIL). `show applications` gecersizdir, USAGE
# metni doner ve ona yapilan grep sessizce hep bos kalir.
#
# NEDEN degiskene aliniyor: `$FSCLI ... | grep -q` deseni `set -o pipefail`
# ile BIRLIKTE hataliydi. `grep -q` ilk eslesmede cikip pipe'i kapatir,
# fs_cli SIGPIPE ile oldurulur, pipefail tum pipeline'i basarisiz sayar ve
# kontrol GECERKEN FAIL uretir. Kucuk ciktilarda tesadufen calisir (fs_cli
# yazmayi bitirmis olur), `show application` gibi buyuk ciktilarda patlar —
# yani kirilgan ve yaniltici. Ciktiyi once degiskene aliyoruz.
APPS=$($FSCLI "show application")
echo "$APPS" | grep -qE "^limit," \
  || fail "'limit' uygulamasi kayitli degil (mod_dptools)"
MODS=$($FSCLI "show modules")
echo "$MODS" | grep -q "^limit,db,mod_db" \
  || fail "'db' limit arka ucu kayitli degil (mod_db)"

echo "--- 2. max_calls.lua PostgreSQL'den dogru degeri okuyor mu ---"
# Cikti kontrolu SIKI: plandaki `grep -qE '(^|[^0-9])2([^0-9]|$)'` deseni
# ciktidaki herhangi bir 2 ile (zaman damgasi, satir numarasi, port) bosa
# gecebilirdi. `max_calls=<n>` formatina ankorluyoruz.
OUT=$($FSCLI "lua max_calls.lua alice tenant1.voip.local" 2>&1)
echo "$OUT" | grep -q "max_calls=2" \
  || fail "max_calls.lua alice icin max_calls=2 dondurmedi. Cikti: $OUT"
echo "$OUT" | grep -qiE "error|traceback|baglantisi kurulamadi" \
  && fail "max_calls.lua alice icin hata/uyari uretti: $OUT"
echo "  alice -> max_calls=2"

echo "--- 3. bilinmeyen kullanicida varsayilana dusuyor, hata vermiyor ---"
OUT2=$($FSCLI "lua max_calls.lua yokboyle tenant1.voip.local" 2>&1)
echo "$OUT2" | grep -qiE "error|traceback" \
  && fail "bilinmeyen kullanicida Lua hatasi: $OUT2"
echo "$OUT2" | grep -q "max_calls=1" \
  || fail "bilinmeyen kullanici varsayilan 1'e dusmedi. Cikti: $OUT2"

echo "--- 4. SQL enjeksiyonuna kapali mi ---"
# Kullanici adi dogrudan SQL'e giriyor (Lua Dbh API'sinde parametreli sorgu
# yok), o yuzden escape'in GERCEKTEN calistigini sinamak gerekiyor.
OUT3=$($FSCLI "lua max_calls.lua alice';DROP_TABLE_TEST--  tenant1.voip.local" 2>&1)
echo "$OUT3" | grep -qiE "error|traceback" \
  && fail "escape edilmemis tirnak Lua/SQL hatasi uretti: $OUT3"
[ "$(q "SELECT count(*) FROM subscriber")" -ge 2 ] \
  || fail "subscriber tablosu zarar gordu — SQL escape calismiyor"

echo "--- 5. GERCEK limit zorlamasi: max_calls=1 iken 2. cagri reddedilmeli ---"
# Plan bunu HIC test etmiyordu; yalnizca Lua'nin degeri okudugunu ve tablonun
# var oldugunu kontrol ediyordu. "Konfigurasyon dogru" ile "davranis dogru"
# arasindaki fark bu projede uc kez isirdi, o yuzden limit'i fiilen zorluyoruz.
UAS_LOG=$(mktemp); P1_LOG=$(mktemp); P2_LOG=$(mktemp)
q "UPDATE subscriber SET max_calls=1 WHERE username='alice';" >/dev/null
MAXCALLS_DIRTY=1

python3 tools/sip-uas-probe.py \
  --proxy "${EXTERNAL_IP}:5060" --domain "tenant1.voip.local" \
  --user bob --password bob123 --wait 30 --media-time 8 > "$UAS_LOG" 2>&1 &
UAS_PID=$!
for i in $(seq 1 40); do grep -q READY "$UAS_LOG" 2>/dev/null && break; sleep 0.5; done
grep -q READY "$UAS_LOG" 2>/dev/null || { cat "$UAS_LOG"; fail "bob kaydolamadi"; }

# 1. cagri: limit icinde, basarili olmali.
python3 tools/sip-call-probe.py \
  --proxy "${EXTERNAL_IP}:5060" --domain "tenant1.voip.local" \
  --user alice --password alice123 --dest bob \
  --hold 9 --rtp-packets 30 --rtp-port 40210 > "$P1_LOG" 2>&1 &
P1_PID=$!
sleep 5

# Sayac kontrolu CAGRI AYAKTAYKEN yapilmali: mod_db limit kaydini cagri
# bitince SILER (release). Cagri sonrasi bakildiginda tablo bos olur ve
# "sayac yazilmiyor" gibi yanlis okunur.
[ "$(qf "SELECT count(*) FROM limit_data WHERE realm='user_calls'")" -ge 1 ] \
  || fail "cagri ayaktayken limit_data'da user_calls kaydi yok — sayac PostgreSQL'e yazilmiyor (db.conf.xml dbname ${FS_DB_NAME} mi?)"
# limit_data'da `count` diye bir kolon YOK (kolonlar: hostname, realm, id,
# uuid). Sayac, AKTIF CAGRI BASINA BIR SATIR olarak tutulur; dolayisiyla
# "kullanim" = satir sayisi.
echo "  cagri sirasinda sayac PostgreSQL'de: $(qf "SELECT realm||'/'||id FROM limit_data WHERE realm='user_calls' LIMIT 1") (aktif satir: $(qf "SELECT count(*) FROM limit_data WHERE realm='user_calls'"))"

# 2. cagri: ayni kullanici, limit asildi -> 200 OK ALMAMALI.
set +e
python3 tools/sip-call-probe.py \
  --proxy "${EXTERNAL_IP}:5060" --domain "tenant1.voip.local" \
  --user alice --password alice123 --dest bob \
  --hold 1 --rtp-packets 5 --rtp-port 40220 > "$P2_LOG" 2>&1
P2_RC=$?
set -e

wait $P1_PID; P1_RC=$?
wait $UAS_PID 2>/dev/null || true
UAS_PID=""

[ "$P1_RC" = "0" ] \
  || { echo "--- 1. cagri ---"; cat "$P1_LOG"; fail "limit icindeki 1. cagri basarisiz oldu"; }
[ "$P2_RC" != "0" ] \
  || { echo "--- 2. cagri ---"; cat "$P2_LOG"; fail "max_calls=1 iken 2. eszamanli cagri KABUL EDILDI — limit uygulanmiyor"; }
# Reddedilmis olmasi YETMEZ, DOGRU SEBEPLE reddedilmeli. limit_exceeded
# extension'i tanimli olmadiginda cagri local-user desenine dusup donguye
# giriyor ve `483 Too Many Hops` aliniyordu: limit "calisiyor" gorunur ama
# arayan anlamsiz bir hata alir. Beklenen: 486 Busy Here (USER_BUSY).
grep -q "SIP/2.0 486" "$P2_LOG" \
  || { echo "--- 2. cagri ---"; cat "$P2_LOG"; fail "2. cagri 486 Busy Here ile reddedilmedi — limit_exceeded extension'i eksik olabilir (483 Too Many Hops = dongu)"; }
echo "  1. cagri kabul, 2. cagri 486 Busy Here ile reddedildi"

echo "--- 6. limit arka ucu core DB (PostgreSQL) mu ---"
# Bu kontrol cagri testinden SONRA yapilir: mod_db `limit_data` tablosunu
# yuklenirken DEGIL, `limit` ILK KEZ kullanildiginda olusturur. Onceye
# alindiginda tablo henuz yoktur ve test yanlis yere FAIL verir.
[ "$(qf "SELECT to_regclass('public.limit_data') IS NOT NULL")" = "t" ] \
  || fail "limit_data tablosu ${FS_DB_NAME} veritabaninda yok — limit db arka ucu devrede degil (sayac bellekte tutuluyor olabilir)"
# Sayacin yazildigi adim 5'te (cagri ayaktayken) dogrulandi. Burada cagri
# BITTIKTEN sonra sayacin SERBEST BIRAKILDIGINI kontrol ediyoruz: kayit
# kalirsa sayac sizar ve kullanici bir daha hic cagri yapamaz.
[ "$(qf "SELECT count(*) FROM limit_data WHERE realm='user_calls' AND id='alice'")" = "0" ] \
  || fail "cagri bittigi halde alice icin limit sayaci sifirlanmadi — sayac siziyor, kullanici kalici olarak bloke olur"
echo "  cagri sonrasi sayac serbest birakildi"

echo "OK: verify-11-maxcalls"
echo "NOT: Bu script KANITLAR:"
echo "     - mod_lua VE mod_db yuklu, 'limit' uygulamasi kayitli,"
echo "     - max_calls.lua PostgreSQL'den GERCEK degeri okuyor (alice=2),"
echo "     - bilinmeyen kullanicida hata vermeden varsayilana dusuyor,"
echo "     - kullanici adindaki tirnak SQL'i bozmuyor (escape calisiyor),"
echo "     - limit durumu PostgreSQL'de (limit_data) tutuluyor,"
echo "     - limit FIILEN ZORLANIYOR: max_calls=1 iken 2. cagri reddediliyor."
