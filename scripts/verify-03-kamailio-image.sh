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

for m in dispatcher auth_db usrloc registrar db_postgres tm rr; do
  docker run --rm --entrypoint sh voip-kamailio -c \
    "test -f /usr/lib/x86_64-linux-gnu/kamailio/modules/${m}.so || \
     test -f /usr/lib/aarch64-linux-gnu/kamailio/modules/${m}.so" \
    || fail "modul yok: ${m}.so"
done

echo "OK: verify-03-kamailio-image"
