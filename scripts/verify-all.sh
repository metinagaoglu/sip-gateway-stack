#!/usr/bin/env bash
# Tum dogrulama scriptlerini sirayla calistirir.
#
# DIKKAT: `set -e` KULLANILMIYOR. Amac ilk hatada durmak degil, TUM
# scriptleri kosup tam bir tablo cikarmak. Tek bir FAIL bile toplam sonucu
# basarisiz yapar (son satirdaki cikis kodu).
set -uo pipefail

cd "$(dirname "$0")/.."

PASS=0; FAIL=0; SKIP=0
FAILED_LIST=""
START_ALL=$SECONDS

for s in scripts/verify-[0-9]*.sh; do
  [ -x "$s" ] || chmod +x "$s"
  printf '%-34s ' "$(basename "$s")"
  START=$SECONDS
  OUT=$("$s" 2>&1)
  RC=$?
  DUR=$((SECONDS - START))

  if [ $RC -ne 0 ]; then
    echo "FAIL  (${DUR}s)"
    # Sadece anlamli satirlari goster: compose gurultusu isaretlenmesin.
    echo "$OUT" | grep -vE "^ (Container|Network|Volume) " | tail -25 | sed 's/^/    /'
    FAIL=$((FAIL+1))
    FAILED_LIST="$FAILED_LIST $(basename "$s")"
  elif echo "$OUT" | grep -q '^ATLANDI'; then
    echo "SKIP  (${DUR}s)"
    SKIP=$((SKIP+1))
  else
    echo "PASS  (${DUR}s)"
    PASS=$((PASS+1))
  fi
done

echo
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP   (toplam $((SECONDS - START_ALL))s)"
[ -n "$FAILED_LIST" ] && echo "basarisiz:$FAILED_LIST"

# Yigin saglik ozeti: testler gecse bile surecler cokmus olabilir.
echo
echo "--- yigin durumu ---"
docker compose ps --format '{{.Service}}\t{{.Status}}' 2>/dev/null || true
RC_FS=$(docker inspect voip-freeswitch --format '{{.RestartCount}}' 2>/dev/null || echo "?")
echo "freeswitch RestartCount: $RC_FS"
if [ "$RC_FS" != "0" ] && [ "$RC_FS" != "?" ]; then
  echo "UYARI: FreeSWITCH bu container omru boyunca $RC_FS kez yeniden basladi."
  echo "       Testler gecse bile bir cokme var; 'docker events' ve"
  echo "       progress.md'deki SIGSEGV bolumune bakin."
fi

[ $FAIL -eq 0 ]
