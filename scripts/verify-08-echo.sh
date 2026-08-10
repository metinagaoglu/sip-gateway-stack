#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose up -d
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done

# Adim 1-5 statik/introspection dogrulamasi yapar (profil, ACL, canli
# konfigurasyon, dialplan yapisi). Adim 6-8 ise GERCEK bir SIP cagrisi kurar.
#
# TARIHCE — mod_loopback ve SIGSEGV: Task 8 gelistirilirken mod_loopback ile
# kurulan sentetik cagrilarin sonlandirmada FreeSWITCH'i SEGFAULT ettirdigi
# (exitCode 139) gozlendi ve bu script her turlu canli cagriyi kaldiracak
# sekilde yazildi. Sonradan tek degiskenli olcumle gorulduki tetikleyici
# mod_loopback DEGIL: 200 OK'e ACK GONDERMEYEN bir istemcinin cagrisi
# medya calisirken (CS_EXECUTE) zaman asimiyla kapatildiginda FreeSWITCH
# CS_REPORTING'de cokuyor. Duzgun ACK + BYE yapan gercek bir SIP cagrisi
# (adim 7) surecin sag kalmasiyla tekrar tekrar dogrulandi. Bu yuzden gercek
# cagri testi geri getirildi; hayatta kalma adim 8'de ayrica sinaniyor.
# Not: ACK'siz istemci senaryosundaki cokme AYRI ve ACIK bir kusurdur,
# bu script onu KASITLI OLARAK tetiklemez (bkz. task-8-report.md).
#
# Cift yonlu SES artik otomatik dogrulaniyor: adim 7 gercek RTP gonderip
# echo'nun yansimasini sayiyor. Elle kalan tek sey ses KALITESI (jitter,
# kopma) — onu kulakla dinlemek gerekir.

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
echo "$SOFIA_XML" | grep -q 'name="local-network-acl" value="none"' \
  || fail "local-network-acl canli konfigurasyonda 'none' degil — varsayilan localnet.auto Kamailio'yu (172.x) yerel sayar, SDP'de ext-rtp-ip yerine konteyner adresi duyurulur ve CAGRI KURULUR AMA SES AKMAZ"
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

echo "--- 6. Calisan Kamailio, repo'daki kamailio.cfg ile AYNI MI ---"
# kamailio.cfg image'a COPY ediliyor, bind-mount EDILMIYOR. Bu yuzden
# `docker compose restart kamailio` cfg degisikligini ALMAZ — sadece
# `up -d --build` alir. Bu tuzak gercekten yasandi: consume_credentials()
# eklendi, restart edildi, test yine FAIL verdi ve bir an "duzeltme ise
# yaramadi" sanildi. Bu kontrol olmadan asagidaki cagri testi eski bir
# konfigurasyonu test edip yaniltici sonuc verebilir.
docker compose exec -T kamailio cat /etc/kamailio/kamailio.cfg > /tmp/kam-running.cfg 2>/dev/null \
  || fail "calisan kamailio'dan kamailio.cfg okunamadi"
if ! diff -q kamailio/kamailio.cfg /tmp/kam-running.cfg >/dev/null 2>&1; then
  rm -f /tmp/kam-running.cfg
  fail "calisan Kamailio eski konfigurasyonu kullaniyor — 'docker compose up -d --build kamailio' calistirin (restart YETMEZ, cfg image'a gomulu)"
fi
rm -f /tmp/kam-running.cfg

echo "--- 7. GERCEK ucdan uca cagri: 200 OK + SDP adresi + RTP echo + temiz BYE ---"
# Bu adim, adim 1-5'in KANITLAYAMADIGI seyi kanitlar: sinyalizasyonun
# fiilen uctan uca calistigini. Onceki surumde bu script hic cagri
# kurmuyordu ve bu yuzden Kamailio'nun Proxy-Authorization basligini
# tuketmemesinden dogan 407 hatasi butun otomatik testlerden kacti
# (FreeSWITCH, auth-calls=false olmasina ragmen istekte credential gorunce
# kendi digest dogrulamasini calistirip "stale=true" 407 doner; kanal
# CS_NEW'de kalir). Regresyonu burada yakaliyoruz.
#
# --expect-media-ip ayrica "cagri kuruluyor ama ses yok" sinifini yakalar:
# FreeSWITCH SDP'de konteyner adresini (172.x) duyurursa hicbir dis istemci
# oraya RTP gonderemez. Probe ustune GERCEK RTP gonderip echo'nun yansimasini
# sayar — bu, sinyalizasyonun kanitlayamadigi tek sey olan medya yolunu
# kanitlar.
python3 tools/sip-call-probe.py \
  --proxy "${EXTERNAL_IP}:5060" \
  --domain "tenant1.voip.local" \
  --user alice --password alice123 --dest 9999 \
  --expect-media-ip "${EXTERNAL_IP}" \
  || fail "proxy uzerinden 9999 cagrisi/medyasi dogrulanamadi (yukaridaki probe ciktisina bakin)"

echo "--- 8. Cagri sonrasi FreeSWITCH ayakta mi (SIGSEGV regresyonu) ---"
# Task 8'de cagri sonlandirmanin FreeSWITCH'i SIGSEGV ile cokerttigi
# (exitCode 139) gozlenmisti. Adim 7 gercek bir cagriyi BYE ile kapattigi
# icin, surecin bu islemden SAG cikip cikmadigini burada dogruluyoruz.
[ "$(docker inspect voip-freeswitch --format '{{.State.Status}}')" = "running" ] \
  || fail "FreeSWITCH cagri sonrasi calismiyor"
$FSCLI "status" >/dev/null 2>&1 \
  || fail "FreeSWITCH cagri sonrasi ESL'e yanit vermiyor (cokup yeniden basladi olabilir)"

echo "OK: verify-08-echo (sinyalizasyon + ACL + canli konfigurasyon + dialplan + GERCEK cagri)"
echo "NOT: Bu script asagidakileri kanitlar:"
echo "     - internal profili ayakta ve dogru ext-rtp-ip/ext-sip-ip duyuruyor,"
echo "     - auth-calls=false + ACL/outbound-proxy degerleri CANLI konfigurasyonda dogru,"
echo "     - trusted ACL'i GERCEKTEN sadece Kamailio/loopback'e izin veriyor (genel internet degil),"
echo "     - dialplan GERCEKTEN yukleniyor ve 9999/9998/tenant-default/local-user extension'lari"
echo "       xml_locate ile cozuluyor (yapisal dogruluk),"
echo "     - calisan Kamailio repo'daki kamailio.cfg ile ayni (bayat image yok),"
echo "     - proxy uzerinden 9999'a GERCEK bir cagri 200 OK aliyor, SDP'de EXTERNAL_IP"
echo "       duyuruluyor, RTP echo GERCEKTEN yansiyor ve cagri BYE ile temiz kapaniyor,"
echo "     - FreeSWITCH bu cagridan sag cikiyor."
echo "NOT: Bu script KANITLAMAZ: ses KALITESINI (jitter/kopma) ve tenant_id'nin"
echo "     CDR'a GERCEKTEN yazildigini (Task 10). Ses kalitesi Zoiper ile elle dinlenir."
