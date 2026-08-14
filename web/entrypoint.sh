#!/bin/sh
set -eu

CERT_DIR=/etc/nginx/certs
CERT="$CERT_DIR/server.crt"
KEY="$CERT_DIR/server.key"

: "${EXTERNAL_IP:?EXTERNAL_IP tanimli olmali}"
: "${SIP_DOMAIN:?SIP_DOMAIN tanimli olmali}"

mkdir -p "$CERT_DIR"

# IDEMPOTENT. Sertifika named volume'da yasar ve VAR OLANA DOKUNULMAZ:
# yeniden uretmek tarayicidaki guvenlik istisnasini gecersiz kilar ve
# kullanicinin onu elle yeniden kabul etmesini gerektirir.
if [ -s "$CERT" ] && [ -s "$KEY" ]; then
    echo "entrypoint: mevcut sertifika kullaniliyor ($CERT)"
else
    echo "entrypoint: sertifika uretiliyor (CN=${EXTERNAL_IP})"
    # SAN sart: modern tarayicilar Common Name'e BAKMAZ, yalnizca
    # subjectAltName'e bakar. IP ile baglaniyoruz, o yuzden IP: girdisi
    # olmadan sertifika hicbir sekilde kabul edilemez.
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -keyout "$KEY" -out "$CERT" \
        -subj "/CN=${EXTERNAL_IP}" \
        -addext "subjectAltName=IP:${EXTERNAL_IP},IP:127.0.0.1,DNS:localhost,DNS:${SIP_DOMAIN},DNS:tenant1.${SIP_DOMAIN}"
    chmod 600 "$KEY"
fi

exec "$@"
