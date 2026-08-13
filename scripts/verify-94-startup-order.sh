#!/usr/bin/env bash
# Baslatma SIRASI dayanikliligi.
#
# Kamailio'nun dispatcher hedefi bir HOSTNAME ('freeswitch') ve Docker DNS
# kaydi ancak o kapsayici ayaga kalkinca olusur. compose'da kamailio'nun
# freeswitch'e `depends_on`'u YOK ve olamaz — FreeSWITCH de Kamailio'yu
# outbound-proxy olarak kullandigi icin karsilikli bagimlilik olurdu.
#
# Dolayisiyla "Kamailio, FreeSWITCH'ten once basliyor" NORMAL bir durumdur ve
# yigin bunu atlatmak zorundadir. flags=0 ile atlatamiyordu: dispatcher
# yuklemesi DNS'i cozemeyince hedefi TAMAMEN atliyor, bir daha denemiyor ve
# butun cagrilar KALICI olarak "503 No Media Server Available" aliyordu.
# Cozum: seed'de flags=8 (DS_PROBING_DST).
#
# Bu test o senaryoyu FIILEN kurar: FreeSWITCH'i durdurup Kamailio'yu yeniden
# baslatir, hedefin yine de yuklendigini dogrular, sonra FreeSWITCH'i geri
# getirip hedefin AKTIF olmasini ve gercek bir cagrinin kurulmasini bekler.
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }
KAMCMD() { docker compose exec -T kamailio kamcmd "$@" 2>/dev/null; }

restore() {
  # Ne olursa olsun yigini calisir durumda birak.
  docker compose up -d freeswitch >/dev/null 2>&1 || true
}
trap restore EXIT

docker compose up -d >/dev/null 2>&1

echo "--- 1. seed'de dispatcher flags=8 (DS_PROBING_DST) mi ---"
# flags=0 olursa bu testin geri kalani zaten basarisiz olur, ama sebebi
# burada acikca soylenmis olsun.
[ "$(q "SELECT flags FROM dispatcher WHERE destination='sip:freeswitch:5060'")" = "8" ] \
  || fail "dispatcher.flags 8 degil — DNS cozulemedigi anda hedef atlanir (db/init/02-seed.sql)"
grep -q "8, 0, 'FreeSWITCH node 1'" db/init/02-seed.sql \
  || fail "02-seed.sql hala flags=0 ile INSERT ediyor — sifirdan kurulumda ayni hata tekrarlanir"

echo "--- 2. FreeSWITCH'i durdur (DNS kaydi kaybolsun) ---"
docker compose stop freeswitch >/dev/null 2>&1
sleep 2

echo "--- 3. Kamailio'yu FreeSWITCH YOKKEN yeniden baslat ---"
docker compose restart kamailio >/dev/null 2>&1
for i in $(seq 1 30); do KAMCMD core.uptime >/dev/null 2>&1 && break; sleep 1; done
KAMCMD core.uptime >/dev/null 2>&1 || fail "Kamailio ayaga kalkmadi"

echo "--- 4. dispatcher hedefi YINE DE yuklenmis olmali ---"
DS=$(KAMCMD dispatcher.list || true)
echo "$DS" | grep -q "sip:freeswitch:5060" \
  || { echo "$DS"; docker compose logs kamailio --since 60s 2>&1 | grep -iE "dispatcher|resolve" | tail -5;
       fail "FreeSWITCH yokken baslatilan Kamailio dispatcher hedefini YUKLEMEDI — flags=8 etkili degil, butun cagrilar kalici 503 alir"; }
echo "  hedef yuklendi (DNS cozulemese bile)"

# Yukleme hatasi loglara DUSMEMELI.
docker compose logs kamailio --since 60s 2>&1 | grep -q "unable to add destination" \
  && fail "loglarda 'unable to add destination' var — hedef atlanmis"

echo "--- 5. FreeSWITCH geri gelince hedef AKTIF olmali ---"
docker compose up -d freeswitch >/dev/null 2>&1
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 60); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done
$FSCLI "status" >/dev/null 2>&1 || fail "FreeSWITCH geri gelmedi"

# ds_ping_interval 30 sn; probing modunda hedefin aktiflesmesi bir ping
# dongusu kadar surebilir.
ACTIVE=0
for i in $(seq 1 45); do
  KAMCMD dispatcher.list | grep -A2 "sip:freeswitch:5060" | grep -qE "FLAGS:\s*A" && { ACTIVE=1; break; }
  sleep 2
done
[ "$ACTIVE" = "1" ] \
  || { KAMCMD dispatcher.list; fail "FreeSWITCH ayakta ama dispatcher hedefi AKTIF olmadi (OPTIONS ping yanit almiyor)"; }
echo "  hedef aktif oldu"

echo "--- 6. bu durumdan sonra GERCEK cagri kurulabiliyor mu ---"
python3 tools/sip-call-probe.py \
  --proxy "${EXTERNAL_IP}:5060" --domain "tenant1.voip.local" \
  --user alice --password alice123 --dest 9999 \
  --hold 1 --rtp-packets 20 --rtp-port 40490 >/tmp/so.log 2>&1 \
  || { cat /tmp/so.log; fail "baslatma sirasi testinden sonra cagri kurulamadi"; }
echo "  cagri kuruldu: $(grep -oE 'alindi=[0-9]+ \([0-9]+%\)' /tmp/so.log || true)"
rm -f /tmp/so.log

echo "OK: verify-94-startup-order"
echo "NOT: Bu script KANITLAR: Kamailio FreeSWITCH'ten ONCE baslasa bile"
echo "     dispatcher hedefi yuklenir (flags=8 probing), FreeSWITCH gelince"
echo "     hedef aktiflesir ve cagri kurulur. flags=0 iken hedef sessizce"
echo "     atlaniyor ve butun cagrilar kalici olarak 503 aliyordu."
