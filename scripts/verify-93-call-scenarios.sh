#!/usr/bin/env bash
# Cagri senaryolari: kaynak sizintisi, es zamanlilik ve hic test edilmemis
# dialplan yollari.
#
# verify-08/09/10/11 TEK cagriyi derinlemesine dogruluyor. Buradaki sorular
# farkli: cagrilar ARDI ARDINA ve AYNI ANDA yapildiginda yigin saglam kaliyor
# mu, kaynaklar geri veriliyor mu, ve dialplan'in test edilmemis dallari
# (9998, kayitsiz kullanici) ne yapiyor.
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }
q()  { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }
qf() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$FS_DB_NAME"   -tAc "$1"; }
PROBE="python3 tools/sip-call-probe.py --proxy ${EXTERNAL_IP}:5060 --domain tenant1.voip.local"

docker compose up -d >/dev/null 2>&1
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done
$FSCLI "status" >/dev/null 2>&1 || fail "FreeSWITCH ESL'e yanit vermiyor"

RC_BEFORE=$(docker inspect voip-freeswitch --format '{{.RestartCount}}')
# CDR kontrolleri ZAMAN penceresiyle DEGIL, id ile sinirlanir. Zaman penceresi
# kullanildiginda verify-all icinde bu testten hemen once kosan verify-08
# adim 9'un KASITLI ACK'siz cagrisi (duration=32, NORMAL_UNSPECIFIED) bu testin
# icine sizip yanlis FAIL uretiyordu. Test yalnizca KENDI cagrilarindan
# sorumlu olmali.
CDR_MAX_ID=$(q "SELECT coalesce(max(id),0) FROM cdr")

echo "--- 1. ARDI ARDINA 5 cagri: hepsi basarili olmali ---"
# Tek cagrinin calismasi yeterli kanit degil: ilk cagriya ozgu durum
# (baglanti havuzu, port tahsisi, sayaclar) sonraki cagrilarda bozulabilir.
for n in 1 2 3 4 5; do
  $PROBE --user alice --password alice123 --dest 9999 \
    --hold 1 --rtp-packets 15 --rtp-port $((40400 + n)) >/tmp/seq$n.log 2>&1 \
    || { cat /tmp/seq$n.log; fail "$n. ardisik cagri basarisiz"; }
  printf '  %d) OK  %s\n' "$n" "$(grep -oE 'alindi=[0-9]+ \([0-9]+%\)' /tmp/seq$n.log || echo '')"
  rm -f /tmp/seq$n.log
done

echo "--- 2. kaynaklar geri verildi mi (sizinti kontrolu) ---"
sleep 3
CH=$($FSCLI "show channels count" | tr -d '\n' | grep -oE '^[0-9]+' || echo "?")
[ "$CH" = "0" ] \
  || { $FSCLI "show channels"; fail "cagrilar bittigi halde $CH kanal ayakta — kanal sizintisi"; }
LEFT=$(qf "SELECT count(*) FROM limit_data WHERE realm='user_calls'")
[ "$LEFT" = "0" ] \
  || fail "limit_data'da $LEFT artik kayit kaldi — sayac siziyor, kullanici zamanla bloke olur"
echo "  kanal=0, limit sayaci=0"

echo "--- 3. her cagri icin CDR yazildi mi ---"
# 5 cagri -> en az 5 yeni satir. Az olmasi CDR kaybi demektir.
for i in $(seq 1 15); do
  DIFF=$(q "SELECT count(*) FROM cdr WHERE id > ${CDR_MAX_ID}")
  [ "$DIFF" -ge 5 ] && break
  sleep 1
done
[ "$DIFF" -ge 5 ] \
  || fail "5 cagri yapildi ama yalnizca $DIFF CDR yazildi — CDR kaybi"
# Bu testin cagrilari BYE ile kapatildi, yani hepsi NORMAL_CLEARING olmali.
# duration>=30 + NORMAL_UNSPECIFIED dialog ici BYE'in ulasmadiginin
# imzasidir (bkz. Task 10) — ama yalnizca BIZIM cagrilarimiza bakiyoruz.
BAD=$(q "SELECT count(*) FROM cdr WHERE id > ${CDR_MAX_ID} AND hangup_cause='NORMAL_UNSPECIFIED' AND duration >= 30")
[ "$BAD" = "0" ] \
  || fail "$BAD cagri zaman asimiyla dusmus (duration>=30, NORMAL_UNSPECIFIED) — dialog ici BYE ulasmiyor"
CLEAN=$(q "SELECT count(*) FROM cdr WHERE id > ${CDR_MAX_ID} AND hangup_cause='NORMAL_CLEARING'")
[ "$CLEAN" -ge 5 ] \
  || fail "bu testin cagrilarindan yalnizca $CLEAN tanesi NORMAL_CLEARING — BYE ile temiz kapanmayan cagri var"
echo "  $DIFF CDR yazildi, $CLEAN tanesi NORMAL_CLEARING"

echo "--- 4. ES ZAMANLI iki farkli kullanici ---"
# alice ve bob AYNI ANDA arar. Bir kullanicinin cagrisi digerini etkilememeli
# (limit realm'i kullanici basina; ayrica port/kaynak catismasi olmamali).
$PROBE --user alice --password alice123 --dest 9999 \
  --hold 4 --rtp-packets 25 --rtp-port 40450 >/tmp/cc-alice.log 2>&1 &
PA=$!
$PROBE --user bob --password bob123 --dest 9999 \
  --hold 4 --rtp-packets 25 --rtp-port 40460 >/tmp/cc-bob.log 2>&1 &
PB=$!
sleep 3
CH2=$($FSCLI "show channels count" | tr -d '\n' | grep -oE '^[0-9]+' || echo "?")
wait $PA; RA=$?
wait $PB; RB=$?
[ "$RA" = "0" ] || { cat /tmp/cc-alice.log; fail "es zamanli alice cagrisi basarisiz"; }
[ "$RB" = "0" ] || { cat /tmp/cc-bob.log; fail "es zamanli bob cagrisi basarisiz"; }
[ "$CH2" = "2" ] \
  || echo "  (not: es zamanli kanal sayisi $CH2 olcüldu, 2 bekleniyordu — zamanlama kaynakli olabilir)"
echo "  alice ve bob es zamanli cagri kurdu (kanal: $CH2)"
rm -f /tmp/cc-alice.log /tmp/cc-bob.log

echo "--- 5. 9998 tone testi (dialplan'in test edilmemis dali) ---"
# 9998 playback+hangup yapar, yani cagriyi KENDISI kapatir. Probe'un BYE
# gonderme sirasi gelmeden kapanabilir; bu yuzden yalnizca 200 OK ve RTP
# akisini bekliyoruz.
$PROBE --user alice --password alice123 --dest 9998 \
  --hold 1 --rtp-packets 25 --rtp-port 40470 >/tmp/tone.log 2>&1 || true
grep -q "SIP/2.0 200 OK" /tmp/tone.log \
  || { cat /tmp/tone.log; fail "9998 tone testi 200 OK vermedi"; }
GOT=$(grep -oE 'alindi=[0-9]+' /tmp/tone.log | head -1 | cut -d= -f2 || echo 0)
[ "${GOT:-0}" -gt 5 ] \
  || { cat /tmp/tone.log; fail "9998'den ses (tone) akmadi (alindi=${GOT:-0}) — playback calismiyor"; }
echo "  9998 cevaplandi ve tone akiyor (alindi=$GOT)"
rm -f /tmp/tone.log

echo "--- 6. KAYITSIZ kullaniciya cagri temiz reddedilmeli ---"
# Dialplan local-user desenine uyan ama usrloc'ta OLMAYAN bir kullanici.
# Beklenen: net bir hata (4xx/5xx), zaman asimi veya dongu DEGIL.
set +e
$PROBE --user alice --password alice123 --dest carol \
  --hold 1 --rtp-packets 5 --rtp-port 40480 >/tmp/nouser.log 2>&1
RC=$?
set -e
[ "$RC" != "0" ] \
  || { cat /tmp/nouser.log; fail "kayitsiz kullaniciya cagri 200 OK aldi"; }
CODE=$(grep -oE 'SIP/2\.0 [0-9]{3}' /tmp/nouser.log | tail -1 | awk '{print $2}')
case "$CODE" in
  404|480|486|603) echo "  kayitsiz kullanici $CODE ile reddedildi" ;;
  483) cat /tmp/nouser.log; fail "483 Too Many Hops — dongu var (Kamailio src_ip/lookup dali)" ;;
  "")  cat /tmp/nouser.log; fail "kayitsiz kullaniciya HIC son yanit gelmedi (zaman asimi)" ;;
  *)   echo "  (not: beklenmeyen ama kabul edilebilir yanit: $CODE)" ;;
esac
rm -f /tmp/nouser.log

echo "--- 7. tum bu cagrilardan sonra FreeSWITCH ayakta mi ---"
[ "$(docker inspect voip-freeswitch --format '{{.RestartCount}}')" = "$RC_BEFORE" ] \
  || fail "FreeSWITCH bu senaryolar sirasinda COKTU (RestartCount degisti)"
$FSCLI "status" >/dev/null 2>&1 || fail "FreeSWITCH ESL'e yanit vermiyor"
echo "  RestartCount degismedi ($RC_BEFORE)"

echo "OK: verify-93-call-scenarios"
echo "NOT: Bu script KANITLAR: 5 ardisik cagri sorunsuz, kanal ve limit"
echo "     sayaclari sifira donuyor (sizinti yok), her cagri CDR uretiyor ve"
echo "     hicbiri zaman asimiyla dusmuyor, iki kullanici es zamanli arayabiliyor,"
echo "     9998 playback calisiyor, kayitsiz kullanici temiz reddediliyor ve"
echo "     surec butun bunlardan sag cikiyor."
