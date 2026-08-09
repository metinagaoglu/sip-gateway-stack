#!/usr/bin/env bash
set -euo pipefail

CONF=/opt/freeswitch/etc/freeswitch

# *.tmpl sablonlarini ortam degiskenleriyle doldur.
# Yalnizca acikca listelenen degiskenler degistirilir; FreeSWITCH'in kendi
# $${...} sozdizimi bozulmasin diye envsubst'a beyaz liste veriliyor.
VARS='${EXTERNAL_IP} ${SIP_DOMAIN} ${RTP_START} ${RTP_END} ${FS_ESL_PASSWORD} ${POSTGRES_USER} ${POSTGRES_PASSWORD} ${POSTGRES_DB} ${FS_DB_NAME} ${TRUNK_NAME} ${TRUNK_HOST} ${TRUNK_USER} ${TRUNK_PASS} ${TRUNK_REGISTER} ${TRUNK_DID}'

find "$CONF" -name '*.tmpl' | while read -r tmpl; do
    out="${tmpl%.tmpl}"
    envsubst "$VARS" < "$tmpl" > "$out"
    echo "entrypoint: $(basename "$tmpl") -> $(basename "$out")"
done

# stdbuf ile stdout/stderr line-buffered yapiliyor: FreeSWITCH stdout bir
# pipe'a yazarken glibc varsayilan olarak tam arabellekli (full-buffered)
# calisiyor, bu da "docker logs" ciktisinin gercek zamanli akmamasina ve
# baslangic hatalarinin gorunmemesine yol aciyordu.
exec stdbuf -oL -eL "$@"
