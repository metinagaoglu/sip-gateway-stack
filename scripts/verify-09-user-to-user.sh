#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose up -d
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done
$FSCLI "status" >/dev/null 2>&1 || fail "FreeSWITCH ESL'e yanit vermiyor"

UAS_LOG=$(mktemp)
UAS_PID=""
cleanup() {
  [ -n "$UAS_PID" ] && kill "$UAS_PID" 2>/dev/null || true
  rm -f "$UAS_LOG"
}
trap cleanup EXIT

echo "--- 1. dispatcher hedefi AKTIF mi ---"
# Bu kontrol once yapilir: FreeSWITCH down/yeniden basliyorsa dispatcher
# hedefi inaktif olur ve cagri "503 No Media Server Available" alir. O
# durumda asagidaki cagri testinin FAIL'i yaniltici olurdu (sorun
# yonlendirmede degil, medya sunucusunun yoklugunda).
DS=$(docker compose exec -T kamailio kamcmd dispatcher.list)
echo "$DS" | grep -q "sip:freeswitch:5060" \
  || fail "dispatcher'da FreeSWITCH hedefi yok"
echo "$DS" | grep -A2 "sip:freeswitch:5060" | grep -qE "FLAGS:\s*A" \
  || fail "dispatcher hedefi AKTIF degil (FLAGS'te A yok) — FreeSWITCH OPTIONS ping'ine yanit vermiyor"

echo "--- 2. bob'un cagrilan taraf olarak kaydi ---"
# NOT: plan bu kontrolu `SELECT count(*) FROM location` ile yapiyordu; bu
# YANLIS. usrloc db_mode=2 (write-back) oldugu icin `location` tablosu
# GERCEK ZAMANLI DEGIL — yeni kayit birkac dakika DB'ye yazilmayabilir.
# Olculdu: UAS "200 OK" aldiktan hemen sonra tabloda bob YOKTU, ama
# `kamcmd ul.dump` onu CS_SYNC olarak gosteriyordu. Bellekteki usrloc
# tek dogru kaynaktir.
python3 tools/sip-uas-probe.py \
  --proxy "${EXTERNAL_IP}:5060" --domain "tenant1.voip.local" \
  --user bob --password bob123 \
  --wait 30 --media-time 3 > "$UAS_LOG" 2>&1 &
UAS_PID=$!

for i in $(seq 1 40); do
  grep -q READY "$UAS_LOG" 2>/dev/null && break
  sleep 0.5
done
grep -q READY "$UAS_LOG" 2>/dev/null || { cat "$UAS_LOG"; fail "bob kaydolamadi"; }

docker compose exec -T kamailio kamcmd ul.dump | grep -q "bob@tenant1.voip.local" \
  || fail "bob usrloc'ta gorunmuyor (kamcmd ul.dump)"
docker compose exec -T kamailio kamcmd ul.dump | grep -q "alice@tenant1.voip.local" \
  || echo "  (uyari: alice kayitli degil — bu test icin gerekli degil, arayan taraf" \
          "proxy_authenticate ile dogrulanir)"
echo "  bob usrloc'ta kayitli"

echo "--- 3. alice -> bob cagrisi: 200 OK + cift yonlu RTP + temiz BYE ---"
python3 tools/sip-call-probe.py \
  --proxy "${EXTERNAL_IP}:5060" --domain "tenant1.voip.local" \
  --user alice --password alice123 --dest bob \
  --expect-media-ip "${EXTERNAL_IP}" \
  --hold 2 --rtp-packets 50 &
CALL_PID=$!

# Cagri ayaktayken kanal sayisi: DONGU kontrolu (plan Step 4). a-leg + b-leg
# = 2 olmali. Surekli artiyorsa Kamailio'nun `src_ip == FS_HOST` dali
# eslesmiyor ve cagri dispatcher'a geri dusup dongu olusturuyor demektir.
sleep 4
CH=$($FSCLI "show channels count" | tr -d '\n' | grep -oE '^[0-9]+' || echo "?")
echo "  cagri sirasinda kanal sayisi: $CH"

wait $CALL_PID || fail "alice -> bob cagrisi basarisiz (yukaridaki probe ciktisi)"
wait $UAS_PID; UAS_RC=$?
UAS_PID=""

echo "--- 4. cagrilan taraf gercekten RTP aldi mi ---"
grep -q "answered=1" "$UAS_LOG" \
  || { cat "$UAS_LOG"; fail "bob cagriyi cevaplamadi"; }
RTP_IN=$(grep -oE 'rtp_in=[0-9]+' "$UAS_LOG" | tail -1 | cut -d= -f2)
[ -n "$RTP_IN" ] && [ "$RTP_IN" -gt 10 ] \
  || { cat "$UAS_LOG"; fail "bob'a RTP ulasmadi (rtp_in=${RTP_IN:-yok}) — tek yonlu ses"; }
echo "  bob $RTP_IN RTP paketi aldi"
[ "$UAS_RC" = "0" ] || fail "UAS probe basarisiz cikti (rc=$UAS_RC)"

echo "--- 5. dongu yok: kanal sayisi 2 olmali ---"
# 2'den fazlaysa her turda yeni bir bacak yaratiliyor demektir.
[ "$CH" = "2" ] \
  || fail "cagri sirasinda kanal sayisi 2 degil ($CH) — dongu olabilir; Kamailio'nun src_ip == FS_HOST dalini kontrol edin"

echo "--- 6. cagri sonrasi FreeSWITCH hala ayakta mi ---"
[ "$(docker inspect voip-freeswitch --format '{{.State.Status}}')" = "running" ] \
  || fail "FreeSWITCH cagri sonrasi calismiyor"
$FSCLI "status" >/dev/null 2>&1 \
  || fail "FreeSWITCH cagri sonrasi ESL'e yanit vermiyor (cokup yeniden basladi olabilir)"

echo "OK: verify-09-user-to-user"
echo "NOT: Bu script KANITLAR:"
echo "     - bob GERCEKTEN kayit oluyor (usrloc, DB degil — db_mode=2 write-back),"
echo "     - alice -> bob cagrisi 180 Ringing sonrasi 200 OK aliyor,"
echo "     - RTP IKI YONLU akiyor (bob paket aliyor, arayan yansimayi aliyor),"
echo "     - cagri sirasinda TAM 2 kanal var (dongu yok),"
echo "     - cagri BYE ile temiz kapaniyor ve FreeSWITCH sag kaliyor."
echo "NOT: Bu script KANITLAMAZ: ses kalitesini ve gercek bir softphone'un"
echo "     (Zoiper) davranisini. Ayrica FreeSWITCH'in bu derlemesinde YARIM"
echo "     KALAN SIP akislarinda SIGSEGV gozlendi (bkz. progress.md) — bu"
echo "     script yalnizca duzgun akisi test eder."
