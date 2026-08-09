#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose up -d postgres kamailio
sleep 5

# Kamailio ayakta mi
docker compose exec -T kamailio kamctl monitor 1 >/dev/null 2>&1 \
  || docker compose exec -T kamailio kamcmd core.version >/dev/null \
  || fail "kamailio yanit vermiyor"

# Kimlik dogrulamasi olmadan REGISTER 401/407 almalidir.
#
# Brief'teki orijinal yaklasim calisan konteynere `apt-get install sipsak`
# yapiyordu: agdan bagimli, konteyneri "immutable" olmaktan cikaran, ve
# `2>/dev/null` ile sessizce yutulan bir kurulum adimi — kurulum basarisiz
# olsa bile script devam edip yanlis bir sonuca varabilirdi. Bunun yerine
# sipsak, kamailio/Dockerfile'a build-time bagimliligi olarak eklendi
# (bkz. Dockerfile'daki "Tesis/hata ayiklama araclari" adimi); burada sadece
# varligini dogruluyoruz.
docker compose exec -T kamailio sh -c 'command -v sipsak' >/dev/null \
  || fail "sipsak image icine gomulu degil (kamailio/Dockerfile guncel mi?)"

# -U: usrloc/REGISTER modu. Bu bayrak olmadan sipsak varsayilan olarak bir
# OPTIONS ping'i gonderir (REGISTER degil) — konfigurasyonumuz OPTIONS'a hic
# yanit vermez (REGISTRAR/INVITE route'lari disinda sessizce dusuruliyor),
# bu yuzden -U olmadan test hicbir sey kanitlamadan gecebilirdi.
# Hedef URI dogrudan 127.0.0.1: sipsak, konteyner icinden calistigi icin
# kamailio'nun kendi loopback'ine ulasir; ${SIP_DOMAIN} (ornegin
# "voip.local") konteyner ici DNS'te cozulmeyebilir ve bu yuzden
# denenmiyor. -H (yerel hostname override) de bilerek KULLANILMIYOR:
# sipsak verilen degeri de cozumlemeye calisiyor ve rasgele bir string
# ("alice" gibi) burada "cannot resolve local hostname" ile basarisiz olur.
OUT=$(docker compose exec -T kamailio sipsak -U -vv -s "sip:alice@127.0.0.1" 2>&1 || true)
echo "$OUT" | grep -qE '401|407' || fail "kimlik dogrulama zorunlu degil (401/407 gelmedi) — acik relay riski"

echo "NOT: Basarili REGISTER dogrulamasi Zoiper ile elle yapilir (Step 6)."
echo "OK: verify-04-register (challenge asamasi)"
