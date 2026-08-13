#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

# grep -o PATTERN'in "eslesme yok" (exit 1) durumu, set -o pipefail altinda
# bir $(...) atamasi icinde script'i durdurmasin diye kullanilan yardimci.
count_matches() { # $1=aranan sabit metin, stdin=icerik
  grep -o -F "$1" 2>/dev/null | wc -l | tr -d ' ' || true
}

docker compose build freeswitch || fail "freeswitch image build edilemedi"
docker compose up -d freeswitch

FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 45); do
  $FSCLI "status" >/dev/null 2>&1 && break
  sleep 2
done

$FSCLI "status" >/dev/null 2>&1 \
  || fail "fs_cli baglanamiyor — event socket bind olmamis olabilir"

$FSCLI "version" | grep -q "1\.10\.12" || fail "beklenmeyen FreeSWITCH surumu"

LOG=$(docker compose logs freeswitch 2>&1)
echo "$LOG" | grep -q "Cannot get information about IP address ::" \
  && fail "event socket hala IPv6'ya bind olmaya calisiyor"
echo "$LOG" | grep -qE "Error Loading module .*(mod_verto|mod_signalwire)" \
  && fail "mod_verto/mod_signalwire hala yuklenmeye calisiliyor"

# --- Defect 3: SCHED_FIFO / SYS_NICE ---
# Log grep asgari kontrol; asil kanit process'in CapEff kumesinde CAP_SYS_NICE
# (bit 23 = 0x800000) bulunmasi ve gercekten SCHED_FIFO ile calismasi —
# cap_add:SYS_NICE compose'dan veya setcap Dockerfile'dan kaybolursa bunlar
# log satiri kelimesi degismeden de sessizce kirilirdi.
echo "$LOG" | grep -qE "Failed to set SCHED_FIFO scheduler|Could not set nice level" \
  && fail "SCHED_FIFO/nice hatasi hala goruluyor"

FS_PID=$(docker compose exec -T freeswitch pgrep -f 'bin/freeswitch' | head -1 | tr -d '\r')
[ -n "$FS_PID" ] || fail "freeswitch process PID bulunamadi"

CAP_EFF_HEX=$(docker compose exec -T freeswitch sh -c "awk '/^CapEff/{print \$2}' /proc/${FS_PID}/status" | tr -d '\r\n')
[ -n "$CAP_EFF_HEX" ] || fail "CapEff /proc/${FS_PID}/status'tan okunamadi"
if [ $(( 0x${CAP_EFF_HEX} & 0x800000 )) -eq 0 ]; then
  fail "CAP_SYS_NICE freeswitch process'inde effective degil (CapEff=${CAP_EFF_HEX}) — cap_add:SYS_NICE veya setcap kaybolmus olabilir"
fi

CHRT_OUT=$(docker compose exec -T freeswitch chrt -p "$FS_PID" 2>/dev/null || true)
echo "$CHRT_OUT" | grep -q "SCHED_FIFO" \
  || fail "freeswitch process SCHED_FIFO ile calismiyor: ${CHRT_OUT}"

for m in mod_pgsql mod_xml_curl mod_cdr_pg_csv mod_lua mod_sofia mod_dptools; do
  $FSCLI "module_exists $m" | grep -q true || fail "modul yuklu degil: $m"
done

# --- Templating mekanizmasinin gercekten calistigini dogrula ---
# entrypoint.sh'nin kendi VARS beyaz listesini kullaniyoruz (kopya/tekrar
# yazmiyoruz ki iki liste birbirinden sapmasin). Her *.tmpl icin: render
# edilmis dosya var mi, beyaz listedeki hicbir ${VAR} render edilmemis halde
# kalmamis mi, ve FreeSWITCH'in kendi $${...} sozdizimi (beyaz listede
# olmadigi icin) DOKUNULMADAN kalmis mi (sablon ile render arasinda '$${'
# sayisi esit mi).
VARS_LINE=$(docker compose exec -T freeswitch grep '^VARS=' /usr/local/bin/entrypoint.sh || true)
[ -n "$VARS_LINE" ] || fail "entrypoint.sh icinde VARS beyaz listesi bulunamadi"
ALLOWLIST=$(echo "$VARS_LINE" | grep -oE '\{[A-Z_]+\}' | tr -d '{}')
[ -n "$ALLOWLIST" ] || fail "VARS beyaz listesi ayristirilamadi: $VARS_LINE"

TMPL_LIST=$(docker compose exec -T freeswitch find /opt/freeswitch/etc/freeswitch -name '*.tmpl' 2>/dev/null | tr -d '\r')
[ -n "$TMPL_LIST" ] || fail "hic .tmpl sablonu bulunamadi (beklenmiyordu)"

while IFS= read -r tmpl; do
  [ -z "$tmpl" ] && continue
  out="${tmpl%.tmpl}"

  OUT_CONTENT=$(docker compose exec -T freeswitch cat "$out" 2>/dev/null) \
    || fail "render edilmemis: $out (sablon: $tmpl)"
  TMPL_CONTENT=$(docker compose exec -T freeswitch cat "$tmpl" 2>/dev/null)

  # Genel kontrol: render sonrasi TEK $ ile baslayan hicbir ${VAR} kalmamali.
  # Repo kurali: tekli $ HER ZAMAN entrypoint'e ait (ciftli $${...} ise
  # FreeSWITCH'in kendisine). Bunu yalnizca bilinen ALLOWLIST'e karsi degil,
  # genel olarak kontrol ediyoruz — ki gelecekte bir .tmpl yeni bir degiskeni
  # kullanip beyaz listeye eklemeyi UNUTURSA da yakalansin (sadece "bilinen"
  # degiskenlerin render edildigini degil, "hicbir kalinti kalmadigini"
  # dogruluyoruz). grep -P negatif lookbehind ile $${...}'in ikinci
  # parcasini (${...}) yanlislikla "kalinti" saymiyoruz. Container icinde
  # calistiriyoruz cunku host'ta (orn. macOS BSD grep) -P desteklenmeyebilir.
  LEFTOVER=$(docker compose exec -T freeswitch grep -oP '(?<!\$)\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$out" 2>/dev/null || true)
  [ -z "$LEFTOVER" ] \
    || fail "render sonrasi kalinti \${...} bulundu ($out): $(echo "$LEFTOVER" | tr '\n' ' ')"

  TMPL_DBL=$(printf '%s' "$TMPL_CONTENT" | count_matches '$${')
  OUT_DBL=$(printf '%s' "$OUT_CONTENT" | count_matches '$${')
  [ "$TMPL_DBL" = "$OUT_DBL" ] \
    || fail "FreeSWITCH'in \$\${...} sozdizimi bozulmus olabilir: $tmpl icinde $TMPL_DBL, $out icinde $OUT_DBL adet '\$\${' var"
done <<EOF
$TMPL_LIST
EOF

# --- ESL, container icinden degil, gercekten disaridan (published port
# uzerinden) erisilebilir mi? docker compose exec zaten loopback sayildigi
# icin ACL'i asar; bu, published port + ACL'in gercekte calistigini kanitlar. ---
verify_esl_external() {
  local password="$1" host="127.0.0.1" port="8021" to=6
  exec 3<>"/dev/tcp/${host}/${port}" 2>/dev/null || return 1
  local line greeting="" reply=""
  while IFS= read -r -t "$to" -u 3 line; do
    greeting="${greeting}${line}"$'\n'
    [ -z "$line" ] && break
  done
  printf 'auth %s\n\n' "$password" >&3 2>/dev/null || { exec 3<&- 3>&- 2>/dev/null; return 1; }
  while IFS= read -r -t "$to" -u 3 line; do
    reply="${reply}${line}"$'\n'
    [ -z "$line" ] && break
  done
  exec 3<&- 3>&- 2>/dev/null
  case "$reply" in
    *"+OK accepted"*) return 0 ;;
    *) return 1 ;;
  esac
}

verify_esl_external "$FS_ESL_PASSWORD" \
  || fail "ESL published port (127.0.0.1:8021) uzerinden host'tan (container disindan) erisim basarisiz — ACL veya port publish bozuk olabilir"

echo "OK: verify-05-freeswitch-boot"
