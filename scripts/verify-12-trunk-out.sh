#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose up -d
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done
$FSCLI "status" >/dev/null 2>&1 || fail "FreeSWITCH ESL'e yanit vermiyor"

# NOT: cikti degiskene alinir, `$FSCLI ... | grep -q` YAPILMAZ. `grep -q` ilk
# eslesmede pipe'i kapatir, fs_cli SIGPIPE ile oluyor ve `set -o pipefail`
# kontrol GECERKEN FAIL uretiyor (Task 11'de yasandi).

echo "--- 1. external profili ayakta mi (trunk kapali olsa da olmali) ---"
SOFIA=$($FSCLI "sofia status")
echo "$SOFIA" | grep -E "^\s*external\s" | grep -q "RUNNING" \
  || { echo "$SOFIA"; fail "external profili RUNNING degil"; }

echo "--- 2. external profil portu compose'da yayinlanan port ile AYNI mi ---"
# Bu esitlik ZORUNLU. FreeSWITCH Contact/Via'ya profil portunu yazar; host'ta
# baska bir porta map edilirse saglayici geri donen dialog isteklerini (ve
# Task 13'te gelen INVITE'lari) YANLIS yere gonderir. Internal profilde tam
# bu tuzak yasandi (ext-sip-port ise yaramadi), o yuzden external'da
# konteyner portu = host portu tutuluyor.
EXT_XML=$($FSCLI "xml_locate configuration configuration name sofia.conf")
echo "$EXT_XML" | grep -q "name=\"sip-port\" value=\"${FS_EXT_SIP_PORT}\"" \
  || fail "external profilin sip-port'u ${FS_EXT_SIP_PORT} degil (canli konfigurasyon)"
# `docker compose port` protokolu AYRI bayrakla ister; "5081/udp" seklinde
# vermek `strconv.ParseUint ... invalid syntax` hatasi verir ve kontrol
# yanlis yere FAIL eder.
PUBLISHED=$(docker compose port --protocol udp freeswitch "${FS_EXT_SIP_PORT}" 2>/dev/null | sed 's/.*://')
[ -n "$PUBLISHED" ] \
  || fail "compose ${FS_EXT_SIP_PORT}/udp portunu yayinlamiyor — saglayici FreeSWITCH'e ulasamaz"
[ "$PUBLISHED" = "${FS_EXT_SIP_PORT}" ] \
  || fail "host portu ($PUBLISHED) konteyner portundan (${FS_EXT_SIP_PORT}) farkli — Contact yanlis adres duyurur"

echo "--- 3. dialplan'da trunk-out kurali var ve gateway adi COZULMUS mu ---"
# xml_locate imzasi: <section> <tag> <tag_attr_name> <tag_attr_val>.
# Plandaki 3 argumanli "xml_locate dialplan context default" GECERSIZ (-ERR bad args).
DIALPLAN=$($FSCLI "xml_locate dialplan context name default")
echo "$DIALPLAN" | grep -q 'name="trunk-out"' \
  || fail "dialplan'da trunk-out extension'i yok"
# Gateway adi CANLI konfigurasyonda cozulmus olmali ve bu kontrol
# `reloadxml` YAPILMADAN gecmeli — cunku sorun tam olarak baslangicta
# ortaya cikiyordu. Plan gateway adini switch.conf'taki bir GLOBAL degiskenle
# (`$${trunk_name}`) veriyordu; FreeSWITCH ilk acilista dialplan'i o
# <variables> blogundan ONCE okudugu icin deger bos cozuluyor ve hedef
# `sofia/gateway//<numara>` oluyordu. reloadxml sonrasi duzeldigi icin elle
# bakan biri sorunu goremezdi: her yeniden baslatmada giden cagrilar
# SESSIZCE bozuk kalirdi. Cozum: dialplan artik bir sablon (default.xml.tmpl)
# ve ad envsubst ile gomuluyor.
echo "$DIALPLAN" | grep -q "sofia/gateway/${TRUNK_NAME}/" \
  || { echo "$DIALPLAN" | grep -A4 'name="trunk-out"'; fail "trunk-out bridge hedefinde gateway adi '${TRUNK_NAME}' cozulmemis (sofia/gateway//... mi?) — dialplan sablondan mi uretiliyor, entrypoint calisti mi?"; }

echo "--- 4. numara deseni: dogru numaralari yakalayip yerel/servis kodlarini BIRAKMALI ---"
# Desen metnini okumak yetmez; hangi numaralarin trunk'a gidecegini FIILEN
# sinamak icin regex'i canli konfigurasyondan cekip test ediyoruz.
PATTERN=$(echo "$DIALPLAN" | grep -A2 'name="trunk-out"' | grep -oE 'expression="[^"]+"' | head -1 | sed 's/expression="//;s/"$//')
[ -n "$PATTERN" ] || fail "trunk-out deseni okunamadi"
echo "  desen: $PATTERN"
check_num() {  # <numara> <eslesmeli: yes|no>
  if printf '%s' "$1" | grep -qE "$PATTERN"; then R=yes; else R=no; fi
  [ "$R" = "$2" ] || fail "numara '$1' icin beklenen eslesme=$2 ama sonuc=$R (desen: $PATTERN)"
}
check_num "+905551234567" yes    # E.164
check_num "00905551234567" yes   # uluslararasi prefiks
check_num "5551234567" yes       # 10 hane
check_num "9999" no              # echo testi trunk'a GITMEMELI
check_num "9998" no              # tone testi
check_num "bob" no               # yerel kullanici adi
check_num "1001" no              # kisa dahili

echo "--- 5. trunk gateway durumu ---"
if [ "${TRUNK_ENABLED}" != "true" ]; then
  # KAPALI MOD: gateway TANIMLI OLMAMALI. Bos TRUNK_HOST ile uretilmis bir
  # gateway saglayiciya sonsuz basarisiz REGISTER gonderir ve loglari kirletir.
  GW=$($FSCLI "sofia status gateway ${TRUNK_NAME}" 2>&1 || true)
  echo "$GW" | grep -qi "Invalid Gateway\|not found\|-ERR" \
    || fail "TRUNK_ENABLED=false oldugu halde '${TRUNK_NAME}' gateway'i tanimli — entrypoint trunk.xml'i silmiyor"
  echo "  TRUNK_ENABLED=false: gateway dogru sekilde devre disi"
  echo
  echo "OK: verify-12-trunk-out (YAPISAL — saglayici yok)"
  echo "NOT: Bu kosuda KANITLANAN: external profili ayakta, portu compose ile"
  echo "     tutarli, dialplan trunk-out kurali var, gateway adi canli"
  echo "     konfigurasyonda cozulmus, numara deseni dogru numaralari yakalayip"
  echo "     9999/9998/bob/1001'i BIRAKIYOR, ve trunk kapaliyken gateway"
  echo "     gercekten devre disi."
  echo "NOT: KANITLANMAYAN: saglayiciya register, gercek giden cagri, ses."
  echo "     Bunun icin .env'de TRUNK_* alanlarini doldurup TRUNK_ENABLED=true"
  echo "     yapin ve bu scripti tekrar calistirin."
  exit 0
fi

# --- ACIK MOD: gercek saglayici ---
[ -n "${TRUNK_HOST}" ] || fail "TRUNK_ENABLED=true ama TRUNK_HOST bos"
[ -n "${TRUNK_USER}" ] || fail "TRUNK_ENABLED=true ama TRUNK_USER bos"

GW=$($FSCLI "sofia status gateway ${TRUNK_NAME}")
echo "$GW" | grep -q "${TRUNK_HOST}" \
  || { echo "$GW"; fail "gateway ${TRUNK_NAME} ${TRUNK_HOST} adresini gostermiyor"; }

if [ "${TRUNK_REGISTER}" = "true" ]; then
  for i in $(seq 1 20); do
    $FSCLI "sofia status gateway ${TRUNK_NAME}" | grep -q "REGED" && break
    sleep 2
  done
  STATE=$($FSCLI "sofia status gateway ${TRUNK_NAME}")
  echo "$STATE" | grep -q "REGED" \
    || { echo "$STATE"; fail "gateway saglayiciya register olamadi (durum REGED degil) — kullanici/sifre/realm veya saglayici tarafindaki IP izni"; }
  echo "  gateway REGED (register modu)"
else
  # IP yetkilendirme modu: register YOK, ama gateway NOREG durumunda ayakta
  # olmali ve ping yanit vermeli.
  STATE=$($FSCLI "sofia status gateway ${TRUNK_NAME}")
  echo "$STATE" | grep -qE "NOREG|UP" \
    || { echo "$STATE"; fail "gateway NOREG/UP durumunda degil (IP yetkilendirme modu)"; }
  echo "  gateway NOREG/UP (IP yetkilendirme modu)"
fi

echo "OK: verify-12-trunk-out (saglayici bagli)"
echo "NOT: KANITLANMAYAN: gercek giden cagrinin karsi tarafi caldirdigi ve"
echo "     cift yonlu ses. Zoiper'dan bir cep numarasi arayarak elle dogrulayin."
echo "     Ses tek yonluyse saglayicinin SRTP/TLS zorunlulugunu kontrol edin"
echo "     (bu planda TLS/SRTP kapsam disi)."
