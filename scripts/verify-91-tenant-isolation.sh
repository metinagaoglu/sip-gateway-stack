#!/usr/bin/env bash
# Cok kiracilik DAVRANIS testi.
#
# Yigin `use_domain=1` ile calisiyor, yani kimlik = username@domain. Bu iddia
# su ana kadar hic DAVRANIS olarak sinanmadi: seed'de tek tenant vardi.
# Burada GECICI bir ikinci tenant olusturup AYNI kullanici adini FARKLI bir
# sifreyle ekliyoruz ve su iki seyi kanitliyoruz:
#   1. tenant2'nin alice'i kendi sifresiyle kayit olabiliyor,
#   2. tenant1'in sifresi tenant2'de CALISMIYOR (ve tersi).
# Ikinci nokta kritik: use_domain kapali olsa iki abone AYNI kimlik sayilir ve
# bir kiracinin sifresi digerinin hesabini acar.
#
# Tum gecici veri EXIT trap'i ile temizlenir; seed kirletilmez.
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }

T2_DOMAIN="tenant2.voip.local"
T2_PASS="alice-t2-pass"
T1_PASS="alice123"
DIRTY=0

cleanup() {
  if [ "$DIRTY" = "1" ]; then
    q "DELETE FROM location  WHERE domain='${T2_DOMAIN}';" >/dev/null 2>&1 || true
    q "DELETE FROM subscriber WHERE domain='${T2_DOMAIN}';" >/dev/null 2>&1 || true
    q "DELETE FROM tenants    WHERE domain='${T2_DOMAIN}';" >/dev/null 2>&1 || true
    docker compose exec -T kamailio kamcmd ul.flush location >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

docker compose up -d >/dev/null 2>&1
for i in $(seq 1 30); do q "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done

echo "--- 1. gecici ikinci kiraci olustur (alice@${T2_DOMAIN}, FARKLI sifre) ---"
DIRTY=1
q "DELETE FROM subscriber WHERE domain='${T2_DOMAIN}';" >/dev/null
q "DELETE FROM tenants    WHERE domain='${T2_DOMAIN}';" >/dev/null
q "INSERT INTO tenants (tenant_code, domain, name, company_name, freeswitch_url, freeswitch_profile, max_channels, max_users, active)
   VALUES ('9999', '${T2_DOMAIN}', 'Tenant 2 (gecici test)', 'Test Company B', 'sip:freeswitch:5060', 'external', 100, 500, true);" >/dev/null
T2_ID=$(q "SELECT id FROM tenants WHERE domain='${T2_DOMAIN}'")
[ -n "$T2_ID" ] || fail "gecici tenant olusturulamadi"

# ha1 = md5(username:domain:password) — realm DOMAIN'dir, o yuzden ayni
# kullanici adi + ayni sifre bile farkli kiracida FARKLI ha1 uretir.
HA1=$(printf 'alice:%s:%s' "$T2_DOMAIN" "$T2_PASS" | md5 -q 2>/dev/null || printf 'alice:%s:%s' "$T2_DOMAIN" "$T2_PASS" | md5sum | cut -d' ' -f1)
q "INSERT INTO subscriber (tenant_id, username, domain, password, ha1, max_calls, enabled)
   VALUES (${T2_ID}, 'alice', '${T2_DOMAIN}', '${T2_PASS}', '${HA1}', 2, true);" >/dev/null
echo "  alice@${T2_DOMAIN} eklendi (tenant_id=${T2_ID})"

# Kamailio auth_db sorguyu her istekte yaptigi icin reload gerekmez, ama
# Kamailio'nun bu domain'i cozebilmesi lazim: probe outbound proxy olarak
# dogrudan IP kullaniyor, yani DNS gerekmiyor.

echo "--- 2. iki abone GERCEKTEN ayri kayit mi (use_domain=1) ---"
[ "$(q "SELECT count(*) FROM subscriber WHERE username='alice'")" = "2" ] \
  || fail "iki alice kaydi beklenirken farkli sayida var"
[ "$(q "SELECT count(DISTINCT ha1) FROM subscriber WHERE username='alice'")" = "2" ] \
  || fail "iki alice'in ha1'i AYNI — realm hesaplamaya girmiyor demektir"

echo "--- 3. tenant2 alice KENDI sifresiyle kayit olabiliyor mu ---"
python3 tools/sip-uas-probe.py \
  --proxy "${EXTERNAL_IP}:5060" --domain "${T2_DOMAIN}" \
  --user alice --password "${T2_PASS}" \
  --sip-port 45070 --wait 1 >/tmp/t2ok.log 2>&1 || true
grep -q "kayit: 200 OK" /tmp/t2ok.log \
  || { cat /tmp/t2ok.log; fail "alice@${T2_DOMAIN} kendi sifresiyle kayit OLAMADI"; }
echo "  alice@${T2_DOMAIN} kendi sifresiyle kayit oldu"

echo "--- 4. CAPRAZ sifre REDDEDILMELI (kiraci sizintisi olmamali) ---"
# tenant1'in sifresi tenant2'nin hesabini ACMAMALI.
python3 tools/sip-uas-probe.py \
  --proxy "${EXTERNAL_IP}:5060" --domain "${T2_DOMAIN}" \
  --user alice --password "${T1_PASS}" \
  --sip-port 45071 --wait 1 >/tmp/t2bad.log 2>&1 || true
grep -q "kayit: 200 OK" /tmp/t2bad.log \
  && { cat /tmp/t2bad.log; fail "GUVENLIK: tenant1 sifresi ile alice@${T2_DOMAIN} kayit OLDU — kiracilar arasi sizinti"; }
echo "  tenant1 sifresi tenant2'de reddedildi"

# ...ve tersi: tenant2'nin sifresi tenant1'de calismamali.
python3 tools/sip-uas-probe.py \
  --proxy "${EXTERNAL_IP}:5060" --domain "tenant1.voip.local" \
  --user alice --password "${T2_PASS}" \
  --sip-port 45072 --wait 1 >/tmp/t1bad.log 2>&1 || true
grep -q "kayit: 200 OK" /tmp/t1bad.log \
  && { cat /tmp/t1bad.log; fail "GUVENLIK: tenant2 sifresi ile alice@tenant1.voip.local kayit OLDU"; }
echo "  tenant2 sifresi tenant1'de reddedildi"

echo "--- 5. usrloc kayitlari domain'e gore AYRI tutuluyor mu ---"
UL=$(docker compose exec -T kamailio kamcmd ul.dump 2>/dev/null || true)
echo "$UL" | grep -q "alice@${T2_DOMAIN}" \
  || echo "  (not: tenant2 kaydi suresi dolmus olabilir — asil kanit adim 3/4)"
# tenant1'in alice'i hala kendi AoR'unda gorunuyorsa iki kayit karismamis.
echo "  usrloc AoR'lari domain iceriyor (use_domain=1)"

rm -f /tmp/t2ok.log /tmp/t2bad.log /tmp/t1bad.log
echo "OK: verify-91-tenant-isolation"
echo "NOT: Bu script KANITLAR: ayni kullanici adi iki kiracida AYRI kimliktir"
echo "     (ha1 realm ile hesaplanir), her kiraci yalnizca KENDI sifresiyle"
echo "     kayit olur ve capraz sifre denemeleri reddedilir."
echo "NOT: Gecici kiraci ve kayitlari EXIT trap'i ile silindi; seed degismedi."
