#!/usr/bin/env bash
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose build kamailio || fail "kamailio image build edilemedi"

HOST_ARCH=$(docker info --format '{{.Architecture}}')
IMG_ARCH=$(docker image inspect voip-kamailio --format '{{.Architecture}}')
case "$HOST_ARCH" in
  aarch64|arm64) EXPECT=arm64 ;;
  x86_64|amd64)  EXPECT=amd64 ;;
  *) fail "bilinmeyen host mimarisi: $HOST_ARCH" ;;
esac
[ "$IMG_ARCH" = "$EXPECT" ] || fail "image mimarisi $IMG_ARCH, beklenen $EXPECT (emulasyon)"

VER=$(docker run --rm --entrypoint kamailio voip-kamailio -v | head -1)
echo "$VER" | grep -q "6\.0\." || fail "beklenmeyen kamailio surumu: $VER"

# kamailio.cfg sozdizim kontrolu. -c/-f gercek CMD'yi kullanmaz ve cfg'yi hic
# yuklemez, o yuzden ayrica calistiriyoruz. DBURL/EXTERNAL_IP/SIP_DOMAIN'i
# compose'un enjekte ettigi degiskenlerle ayni adlarla veriyoruz cunku
# `kamailio -c`, cfg'deki $env(...) substitutionlari build-time'da degil
# calisma zamaninda gordugu ortam degiskenleriyle cozer; deger tanimsizsa
# parser "unclosed string" hatasi ile durur (bkz. task-3-report.md). Bu yuzden
# kontrol Dockerfile'a build-time RUN olarak degil, buraya konuldu.
docker run --rm \
    -e EXTERNAL_IP=127.0.0.1 \
    -e SIP_DOMAIN=voip.local \
    -e DBURL="postgres://u:p@postgres:5432/db" \
    --entrypoint kamailio voip-kamailio -c -f /etc/kamailio/kamailio.cfg \
    || fail "kamailio.cfg sozdizimi hatali (kamailio -c basarisiz)"

for m in dispatcher auth_db usrloc registrar db_postgres tm rr; do
  OUT=$(docker run --rm --entrypoint sh voip-kamailio -c \
    "test -f /usr/lib/x86_64-linux-gnu/kamailio/modules/${m}.so || \
     test -f /usr/lib/aarch64-linux-gnu/kamailio/modules/${m}.so" 2>&1) \
    || fail "modul kontrolu basarisiz: ${m}.so (docker run cikisi: ${OUT:-yok})"
done

echo "OK: verify-03-kamailio-image"
