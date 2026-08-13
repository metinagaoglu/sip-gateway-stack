#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

q() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }

docker compose up -d postgres kamailio
sleep 5

# Kamailio ayakta mi
docker compose exec -T kamailio kamctl monitor 1 >/dev/null 2>&1 \
  || docker compose exec -T kamailio kamcmd core.version >/dev/null \
  || fail "kamailio yanit vermiyor"

# Brief'teki orijinal yaklasim calisan konteynere `apt-get install sipsak`
# yapiyordu: agdan bagimli, konteyneri "immutable" olmaktan cikaran, ve
# `2>/dev/null` ile sessizce yutulan bir kurulum adimi — kurulum basarisiz
# olsa bile script devam edip yanlis bir sonuca varabilirdi. Bunun yerine
# sipsak, kamailio/Dockerfile'a build-time bagimliligi olarak eklendi
# (bkz. Dockerfile'daki "Tesis/hata ayiklama araclari" adimi); burada sadece
# varligini dogruluyoruz.
docker compose exec -T kamailio sh -c 'command -v sipsak' >/dev/null \
  || fail "sipsak image icine gomulu degil (kamailio/Dockerfile guncel mi?)"

# ============================================================
# Negatif yol: kimlik dogrulamasi olmadan REGISTER 401/407 almali
# ============================================================
#
# -U: usrloc/REGISTER modu. Bu bayrak olmadan sipsak varsayilan olarak bir
# OPTIONS ping'i gonderir (REGISTER degil) — konfigurasyonumuz OPTIONS'a hic
# yanit vermez (REGISTRAR/INVITE route'lari disinda sessizce dusuruliyor),
# bu yuzden -U olmadan test hicbir sey kanitlamadan gecebilirdi.
# Hedef URI dogrudan 127.0.0.1: sipsak, konteyner icinden calistigi icin
# kamailio'nun kendi loopback'ine ulasir; boylece bu negatif test herhangi
# bir DNS/host cozumlemesine bagimli degildir.
NEG_OUT=$(docker compose exec -T kamailio sipsak -U -vv -s "sip:alice@127.0.0.1" 2>&1 || true)

# ONEMLI: grep -qE '401|407' (eski hali) SIP mesaji disindaki HERHANGI bir
# alanda (Call-ID, branch tag, port, byte sayisi, gecikme suresi...) 401/407
# rastlantisal olarak gecerse SESSIZCE DOGRU doner — kimlik dogrulamayi
# tamamen devre disi birakan bir regresyon bile "OK" verebilir. Bunun yerine
# assertion, gercek SIP durum satirina (^SIP/2.0 40[17] ) ve/veya meydan
# okuma basligina (WWW-Authenticate:) ANKORLANIYOR. Format, gercek sipsak
# ciktisindan dogrulandi (bkz. task-4-report.md ek notu): durum satiri satir
# basinda bosluksuz baslıyor, "\r" ile bitiyor — "^SIP/2\.0 40[17] " bunu
# guvenle yakalar.
echo "$NEG_OUT" | grep -qE '^SIP/2\.0 40[17] ' \
  || fail "kimlik dogrulama zorunlu degil (gercek 401/407 durum satiri gelmedi) — acik relay riski"
echo "$NEG_OUT" | grep -qE '^WWW-Authenticate: Digest' \
  || fail "401/407 geldi ama WWW-Authenticate: Digest basligi yok — meydan okuma eksik"

echo "OK: negatif yol (kimlik dogrulamasiz REGISTER reddedildi)"

# ============================================================
# Pozitif yol: dogru kimlik bilgileriyle REGISTER kabul edilmeli
# ============================================================
#
# Bu olmadan, tamamen bozuk bir yapilandirma (yanlis realm, yanlis
# password_column, kirik ha1 sorgusu...) HER isteği reddeder ve negatif test
# yine de gecer — "dogru calisiyor" ile "tamamen bozuk" birbirinden
# ayirt edilemez. Domain mutlaka tenant1.voip.local olmali: seed, ha1'i
# md5('alice:tenant1.voip.local:alice123') olarak hesapladi (bkz.
# db/init/02-seed.sql); digest ancak bu domain/realm ile dogrulanir.
# tenant1.voip.local, docker-compose.yml'deki kamailio servisinin
# extra_hosts'u araciligiyla 127.0.0.1'e cozuluyor (konteyner yeniden
# olusturulsa da kalici; elle /etc/hosts girisi degil).
#
# -u alice ZORUNLU: -u verilmeden sipsak, digest kullanici adini URI'den
# yanlis cikariyor ("alice@" — sondaki '@' ile), bu da subscriber tablosuyla
# eslesmeyip sonsuz 401 dongusune yol aciyor (elle dogrulandi).
#
# Ayni kullanici/domain icin onceki calistirmalardan kalan location
# satirlarini (hem Postgres hem kamailio'nun bellek-ici usrloc kaydini)
# temizleyerek testi tekrar calistirilabilir kiliyoruz. ul.rm basarisiz
# olabilir (AoR zaten yoksa) — bu bir hata degil.
cleanup_location() {
    q "DELETE FROM location WHERE username='alice' AND domain='tenant1.voip.local';" >/dev/null
    docker compose exec -T kamailio kamcmd ul.rm location alice@tenant1.voip.local >/dev/null 2>&1 || true
}
cleanup_location

# -vvv (sipsak'in en yuksek ayrintisi, -v en fazla 3 kez): -vv seviyesinde
# basarili kayit sadece "OK" / "All usrloc tests completed successful."
# ozetini basiyor, gercek "SIP/2.0 200 OK" satirini DOKMUYOR (elle
# dogrulandi) — assertion'in gercek durum satirina ankorlanabilmesi icin
# -vvv gerekli.
POS_OUT=$(docker compose exec -T kamailio sipsak -U -vvv \
            -s "sip:alice@tenant1.voip.local" -u alice -a alice123 2>&1 || true)

echo "$POS_OUT" | grep -qE '^SIP/2\.0 200 ' \
  || fail "dogru sifreyle REGISTER kabul edilmedi (200 OK gelmedi) — config bozuk olabilir: $POS_OUT"

# --- Ani kanit: kamailio'nun kendi bellek-ici usrloc goruntusu (ul.dump) ---
#
# usrloc, "db_mode"=2 (write-back) ile calisiyor: yeni kayitlar Postgres'e
# ANINDA degil, usrloc'un kendi periyodik zamanlayicisiyla (gozlemlenen
# gecikme: birkac saniye ile ~40 saniye arasi, zamanlayicinin faz konumuna
# bagli) yaziliyor. Bu, db_mode=2'nin performans icin bilincli tasarimi —
# kamailio.cfg'ye dokunulmadan degistirilecek bir "hata" degil. O yuzden
# "REGISTER kabul edildi mi ve gercekten kaydedildi mi" sorusunun ANINDA ve
# guvenilir cevabi kamailio'nun kendi "location tablosu" (usrloc) gorunumu:
# `kamcmd ul.dump`. AoR bloğu, bir SONRAKI "AoR:" satirina kadar (haric)
# awk ile sinirlaniyor ki baska bir kullanicinin (ornegin bob) kaydi yanlislikla
# bu kontrolu gecirmesin — cleanup_location'dan hemen sonra alinan taban
# olcum, ayni AoR'nin eski (silinmis/suresi dolmus) kayitlarinin "Expires:
# deleted"/"expired" gosterdigini, sayisal bir "Expires: N" GOSTERMEDIGINI
# dogruladi (bkz. task-4-report.md), bu yuzden bu kontrol asagida sahte-gecer
# degil.
UL_OUT=$(docker compose exec -T kamailio kamcmd ul.dump 2>&1)
ALICE_UL_BLOCK=$(echo "$UL_OUT" | awk '
  /AoR: alice@tenant1\.voip\.local/ { p=1 }
  p && /AoR:/ && !/AoR: alice@tenant1\.voip\.local/ { exit }
  p { print }
')
echo "$ALICE_UL_BLOCK" | grep -qE 'Expires: [0-9]+' \
  || fail "REGISTER 200 OK dondu ama kamailio'nun bellek-ici usrloc kaydinda (ul.dump) alice icin aktif bir contact yok"

# --- Kalici kanit: satir gercekten Postgres 'location' tablosuna yazilmali ---
#
# db_mode=2'nin write-back gecikmesi yuzunden (yukarida aciklandi) kisa bir
# sure bekleyip yokluyoruz; zamanlayicinin bir sonraki turunu kacirmamak icin
# ust sinir 70 saniye (gozlemlenen en kotu durumun uzerinde guvenlik payi).
ROWS=0
for _ in $(seq 1 14); do
    ROWS=$(q "SELECT count(*) FROM location WHERE username='alice' AND domain='tenant1.voip.local';")
    [ "$ROWS" -ge 1 ] && break
    sleep 5
done
[ "$ROWS" -ge 1 ] \
  || fail "REGISTER 200 OK dondu ve usrloc bellekte goruldu ama 70sn icinde Postgres 'location' tablosuna yazilmadi"

# Test kalintisini temizle: bu satir seed verisi degil, yalnizca bu
# calistirmanin kanitidir; ikinci bir calistirma bu yuzden basarisiz
# olmamali.
cleanup_location

echo "OK: pozitif yol (dogru sifreyle REGISTER kabul edildi, location'a yazildi)"
echo "OK: verify-04-register"
