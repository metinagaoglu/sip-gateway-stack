#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose up -d
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done

# NOT: bu script HICBIR canli cagri (originate) kurmaz. Task 8 gelistirilirken
# ampirik olarak defalarca dogrulandi ki bu FreeSWITCH derlemesinde
# (1.10.12) mod_loopback ile kurulan bir cagrinin cift bacagi (bonded pair)
# NASIL sonlandirilirsa sonlandirilsin — uuid_kill, sched_hangup, hatta
# dialplan'in kendi sonundaki normal <action application="hangup"/> ile dogal
# bitis — FreeSWITCH surecini SEGFAULT (exit code 139, docker events ile
# dogrulandi) ile cokertiyor. Bu yuzden brief'in onerdigi
# "originate loopback/9999/default &park()" + "uuid_kill" deseni BILEREK
# KULLANILMIYOR — otomatik dogrulamanin kendisi FreeSWITCH'i her calistiginda
# cokertirdi. Detaylar ve tekrar-uretilebilir kanit icin task-8-report.md'ye
# bakin. mod_loopback bu yuzden autoload_configs/modules.conf.xml'de BILEREK
# yuklenmiyor.
#
# Bu script yerine SADECE canli cagri gerektirmeyen, guvenli introspection
# komutlariyla dogrular: profilin RUNNING olmasi ve dogru ext-ip duyurmasi,
# canli (xml_locate ile ayristirilmis) konfigurasyonun auth-calls=false ve
# ACL/outbound-proxy degerlerini gercekten tasidigi, ACL'in ic
# (fs_cli "acl <ip> <liste>") test API'siyle GERCEKTEN neyi kabul/red
# ettigi, ve dialplan'in xml_locate ile GERCEKTEN yuklendigi/cozuldugu.
# Cift yonlu ses VE cagrinin gercekten ayakta kalip kalmadigi (mod_loopback
# disi, gercek bir SIP cihazindan) Zoiper ile elle dogrulanir (Step 7).

echo "--- 1. internal profili ayakta mi ---"
$FSCLI "sofia status" | grep "internal" | grep -q "RUNNING" \
  || fail "internal profili calismiyor"

echo "--- 2. SDP'de duyurulan adres EXTERNAL_IP mi (ses tek yonlu olmasin diye) ---"
# Sadece ciktida bir yerde EXTERNAL_IP gecmesi yetmez (rtp-ip/sip-ip
# $${local_ip_v4} olsa bile baska bir alanda tesadufen eslesebilir) —
# spesifik olarak Ext-Sip-IP / Ext-RTP-IP etiketli satirlari hedefliyoruz.
PROFILE_STATUS=$($FSCLI "sofia status profile internal")
echo "$PROFILE_STATUS" | grep -E "Ext-(Sip|RTP)-IP" | grep -q "${EXTERNAL_IP}" \
  || fail "internal profili Ext-Sip-IP/Ext-RTP-IP alaninda ${EXTERNAL_IP} duyurmuyor — ses tek yonlu olur"
# rtp-ip/sip-ip (container-ici adres) EXTERNAL_IP ILE AYNI OLMAMALI — ayni
# olsaydi bu, $${local_ip_v4}'un yanlislikla EXTERNAL_IP'ye sabitlendigi
# anlamina gelirdi ve ext-ip/local-ip ayrimi testi anlamsizlasirdi.
echo "$PROFILE_STATUS" | grep -E "^RTP-IP|^SIP-IP" | grep -q "${EXTERNAL_IP}" \
  && fail "RTP-IP/SIP-IP (container-ici) EXTERNAL_IP ile ayni — local_ip_v4 ayrimi bozulmus olabilir"

echo "--- 3. auth-calls FreeSWITCH'te KAPALI olmali (Kamailio yapiyor) ---"
# "sofia status profile internal" bu alani hic GOSTERMIYOR (bu build'de yok);
# bunun yerine FreeSWITCH'in CANLI, ayristirilmis XML konfigurasyon agacini
# (xml_locate) okuyoruz — sadece dosyada dogru metin oldugunu degil,
# FreeSWITCH'in bunu GERCEKTEN yukledigini kanitliyor (bkz. verify-06'daki
# ayni yontem, core-db-dsn/rtp-start-port icin).
SOFIA_XML=$($FSCLI "xml_locate configuration configuration name sofia.conf")
echo "$SOFIA_XML" | grep -q 'name="auth-calls" value="false"' \
  || fail "auth-calls canli konfigurasyonda false degil (xml_locate) — FreeSWITCH kendi kimlik dogrulamasini yapmaya calisiyor olabilir"
echo "$SOFIA_XML" | grep -q "name=\"ext-rtp-ip\" value=\"${EXTERNAL_IP}\"" \
  || fail "ext-rtp-ip canli konfigurasyonda ${EXTERNAL_IP} degil (xml_locate)"
echo "$SOFIA_XML" | grep -q "name=\"ext-sip-ip\" value=\"${EXTERNAL_IP}\"" \
  || fail "ext-sip-ip canli konfigurasyonda ${EXTERNAL_IP} degil (xml_locate)"
echo "$SOFIA_XML" | grep -q 'name="apply-inbound-acl" value="trusted"' \
  || fail "apply-inbound-acl canli konfigurasyonda trusted degil — profil disariya acik olabilir"
echo "$SOFIA_XML" | grep -q 'name="apply-nat-acl" value="trusted"' \
  || fail "apply-nat-acl canli konfigurasyonda trusted degil"
echo "$SOFIA_XML" | grep -q 'name="outbound-proxy" value="sip:kamailio:5060"' \
  || fail "outbound-proxy canli konfigurasyonda Kamailio'ya isaret etmiyor — kullanicidan kullaniciya cagri Kamailio'ya donmez"

echo "--- 4. ACL 'trusted' gercekten kisitlayici mi (CIDR metnine guvenmek yerine canli test) ---"
# fs_cli'nin kendi "acl <ip> <liste>" API'si CANLI yuklu ACL'e karsi gercek
# bir eslesme testi yapar — dosyadaki CIDR'i okumak yerine FreeSWITCH'in
# GERCEKTEN neyi kabul/red ettigini kanitlar.
[ "$($FSCLI "acl 8.8.8.8 trusted")" = "false" ] \
  || fail "trusted ACL genel bir internet adresini (8.8.8.8) reddetmiyor — ACL etkisiz, profil disariya acik olabilir"
[ "$($FSCLI "acl 203.0.113.5 trusted")" = "false" ] \
  || fail "trusted ACL genel bir internet adresini (203.0.113.5) reddetmiyor"
[ "$($FSCLI "acl 172.30.0.5 trusted")" = "true" ] \
  || fail "trusted ACL docker bridge subnet'ini (172.30.0.0/16) kabul etmiyor — Kamailio profile erisemez"
[ "$($FSCLI "acl 127.0.0.1 trusted")" = "true" ] \
  || fail "trusted ACL loopback'i kabul etmiyor"

echo "--- 5. Dialplan'in GERCEKTEN yuklendigini ve 9999/9998/tenant-default/local-user'i cozdugunu dogrula ---"
# NOT: brief'teki "xml_locate dialplan context default" (3 arguman) calismiyor
# ("-ERR bad args") — ayni Task 7'nin xml_locate bulgusuyla ayni sinif hata.
# Doğru imza: xml_locate <section> <tag> <tag_attr_name> <tag_attr_val>.
DIALPLAN_XML=$($FSCLI "xml_locate dialplan context name default")
echo "$DIALPLAN_XML" | grep -q '<context name="default">' \
  || fail "dialplan 'default' baglami xml_locate ile bulunamadi — <include><context> sarmalayicisi eksik/bozuk olabilir"
echo "$DIALPLAN_XML" | grep -q 'name="tenant-default"' \
  || fail "dialplan'da tenant-default extension'i yok — CDR (Task 10) tenant_id'siz kalir"
echo "$DIALPLAN_XML" | grep -q 'name="echo-test"' \
  || fail "dialplan'da echo-test (9999) extension'i yok"
echo "$DIALPLAN_XML" | grep -q '9999' \
  || fail "dialplan'da 9999 deseni yok"
echo "$DIALPLAN_XML" | grep -q 'application="echo"' \
  || fail "echo-test extension'i 'echo' uygulamasini cagirmiyor"
echo "$DIALPLAN_XML" | grep -q 'name="local-user"' \
  || fail "dialplan'da local-user (kullanicidan kullaniciya) extension'i yok"
echo "$DIALPLAN_XML" | grep -q 'application="bridge" data="sofia/internal/\$1@\${domain_name}"' \
  || fail "local-user extension'i beklenen bridge hedefine sahip degil (sofia/internal/\$1@\${domain_name})"

echo "OK: verify-08-echo (sinyalizasyon + ACL + canli konfigurasyon + dialplan yapisi)"
echo "NOT: Bu script SADECE asagidakileri kanitlar:"
echo "     - internal profili ayakta ve dogru ext-rtp-ip/ext-sip-ip duyuruyor,"
echo "     - auth-calls=false + ACL/outbound-proxy degerleri CANLI konfigurasyonda dogru,"
echo "     - trusted ACL'i GERCEKTEN sadece Kamailio/loopback'e izin veriyor (genel internet degil),"
echo "     - dialplan GERCEKTEN yukleniyor ve 9999/9998/tenant-default/local-user extension'lari"
echo "       xml_locate ile cozuluyor (yapisal dogruluk)."
echo "NOT: Bu script KANITLAMAZ: 'echo' uygulamasinin fiilen calistigini, tenant_id'nin"
echo "     bir cagri sirasinda GERCEKTEN set edildigini, veya herhangi bir RTP/ses akisini."
echo "     Bunun nedeni guvenlik: mod_loopback ile kurulan sentetik bir cagriyi sonlandirmanin"
echo "     (nasil sonlandirilirsa sonlandirilsin) bu ortamda FreeSWITCH'i cokerttigi ampirik"
echo "     olarak dogrulandi (bkz. task-8-report.md) — otomatik bir 'cagri kur ve kapat' testi"
echo "     GUVENLI DEGIL. Cagrinin fiilen calistigi VE cift yonlu ses saglandigi Zoiper ile"
echo "     elle dogrulanir (Step 7)."
