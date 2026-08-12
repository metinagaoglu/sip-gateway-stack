#!/usr/bin/env bash
set -euo pipefail

CONF=/opt/freeswitch/etc/freeswitch

# *.tmpl sablonlarini ortam degiskenleriyle doldur.
# Yalnizca acikca listelenen degiskenler degistirilir; FreeSWITCH'in kendi
# $${...} sozdizimi bozulmasin diye envsubst'a beyaz liste veriliyor.
VARS='${EXTERNAL_IP} ${SIP_DOMAIN} ${FS_SIP_PORT} ${FS_EXT_SIP_PORT} ${RTP_START} ${RTP_END} ${FS_ESL_PASSWORD} ${POSTGRES_USER} ${POSTGRES_PASSWORD} ${POSTGRES_DB} ${FS_DB_NAME} ${TRUNK_NAME} ${TRUNK_HOST} ${TRUNK_USER} ${TRUNK_PASS} ${TRUNK_REGISTER} ${TRUNK_DID}'

find "$CONF" -name '*.tmpl' | while read -r tmpl; do
    out="${tmpl%.tmpl}"
    envsubst "$VARS" < "$tmpl" > "$out"
    echo "entrypoint: $(basename "$tmpl") -> $(basename "$out")"
done

# Trunk kapaliyken gateway tanimini KALDIR. Aksi halde sablon bos TRUNK_HOST
# ile uretilir ve FreeSWITCH gecersiz bir adrese sonsuz REGISTER denemesi
# yapar; loglar kirlenir ve "gateway var" gibi gorunur.
if [ "${TRUNK_ENABLED:-false}" != "true" ]; then
    rm -f "$CONF/sip_profiles/external/trunk.xml"
    echo "entrypoint: TRUNK_ENABLED=false, trunk gateway devre disi"
fi

# stdbuf ile stdout/stderr line-buffered yapiliyor: FreeSWITCH stdout bir
# pipe'a yazarken glibc varsayilan olarak tam arabellekli (full-buffered)
# calisiyor, bu da "docker logs" ciktisinin gercek zamanli akmamasina ve
# baslangic hatalarinin gorunmemesine yol aciyordu.
exec stdbuf -oL -eL "$@"
