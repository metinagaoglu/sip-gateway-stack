# VoIP Stack PostgreSQL Rebuild — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kamailio ve FreeSWITCH'in tamamen PostgreSQL üzerinden çalıştığı, tek `docker-compose.yml` ile hem yerelde hem sunucuda birebir aynı şekilde ayağa kalkan bir SIP stack'i kurmak ve bir SIP trunk üzerinden gerçek çağrı ile doğrulamak.

**Architecture:** Kamailio edge'de registrar + digest auth + dispatcher görevi görür; FreeSWITCH B2BUA olarak medyayı anchor'lar ve PostgreSQL'e dört katmanda bağlanır (core DB, xml_curl directory/dialplan, CDR, mod_lua doğrudan sorgu). Kamailio medya yoluna hiç girmez, bu yüzden rtpengine yoktur. Yerel/sunucu taşınabilirliği yalnızca `.env` ile sağlanır.

**Tech Stack:** Docker Compose v2 · PostgreSQL 16 · Kamailio 6.0.6 (debian bookworm, `deb.kamailio.org`) · FreeSWITCH 1.10.12 (kaynaktan derleme, debian bullseye) · Python 3.11 + Flask (xmlapi) · Lua (mod_lua)

**Spec:** `docs/superpowers/specs/2026-08-08-voip-stack-pgsql-trunk-design.md`

---

## Global Constraints

Her task'ın gereksinimleri bu bölümü kapsar.

- **macOS'a özgü hiçbir şey yazılmayacak.** Yerel ile sunucu arasındaki tek fark `.env` içeriğidir. Host'a özel yol, `ipconfig`, `brew`, `host.docker.internal` kullanımı yasak.
- **Tek compose dosyası:** `docker-compose.yml`. `docker-compose.host.yml` yalnızca opsiyonel Linux override'ıdır ve varsayılan akışta kullanılmaz.
- **`version:` anahtarı kullanılmayacak** — Compose v2'de kaldırıldı, uyarı üretir.
- **Hiçbir dosya silinmeyecek.** Eski dokümanlar `docs/archive/`'e, eski compose ve `init.sql` `legacy/`'ye `git mv` ile taşınır.
- **Volume adı `voip_pg_data`** — mevcut `pg_data` volume'üne dokunulmaz.
- **Sırlar yalnızca `.env`'de.** Hiçbir config dosyasına, Dockerfile'a veya compose'a şifre gömülmeyecek. `.env` `.gitignore`'da, `.env.example` versiyonlanır.
- **Sürümler sabitlenecek:** FreeSWITCH `v1.10.12`, sofia-sip `v1.13.18`, spandsp commit `0d2e6ac65e0e8f53d652665a743015a88bf048d4`. `master`/`latest` klonlaması yasak.
- **FreeSWITCH base image bu planda `debian:bullseye-slim` kalır.** Bookworm geçişi ayrı bir plandır (spec §10).
- **RTP aralığı:** `16384–16403` (20 port). Genişletilmeyecek.
- **Her task bir commit ile biter.** Doğrulama scripti geçmeden commit yok.
- Doğrulama scriptleri `set -euo pipefail` ile başlar ve başarısızlıkta sıfırdan farklı kod döner.

---

## File Structure

| Dosya | Sorumluluk |
|---|---|
| `.env.example` | Tüm yapılandırmanın tek şablonu; versiyonlanır |
| `.env` | Ortama özel gerçek değerler; `.gitignore`'da |
| `docker-compose.yml` | Servis tanımları, ağ, volume, port yayınları |
| `docker-compose.host.yml` | Opsiyonel Linux sunucu override'ı (host network) |
| `db/init/01-schema.sql` | Kamailio + CDR şeması (mevcut `init_full_pgsql.sql`'den şema kısmı) |
| `db/init/02-seed.sql` | Tenant, kullanıcı, dispatcher, dialplan başlangıç verisi |
| `db/init/03-freeswitch-db.sh` | `freeswitch` veritabanını oluşturur (env interpolasyonu gerektiği için `.sh`) |
| `kamailio/Dockerfile` | Native arm64 Kamailio 6.0.6 image'ı |
| `kamailio/kamailio.cfg` | Tüm SIP yönlendirme mantığı |
| `freeswitch/Dockerfile` | Sürümü sabitlenmiş kaynak derlemesi + entrypoint |
| `freeswitch/entrypoint.sh` | `.env` değerlerini config şablonlarına enjekte eder |
| `freeswitch/conf/autoload_configs/modules.conf.xml` | Yüklenecek modül listesi |
| `freeswitch/conf/autoload_configs/event_socket.conf.xml` | ESL, IPv4 bind |
| `freeswitch/conf/autoload_configs/switch.conf.xml` | `core-db-dsn`, RTP port aralığı |
| `freeswitch/conf/autoload_configs/xml_curl.conf.xml` | directory + dialplan binding'leri |
| `freeswitch/conf/autoload_configs/cdr_pg_csv.conf.xml` | CDR şema eşlemesi |
| `freeswitch/conf/autoload_configs/acl.conf.xml` | Kamailio güven listesi |
| `freeswitch/conf/sip_profiles/internal.xml.tmpl` | Dahili profil şablonu (auth yok, ACL var) |
| `freeswitch/conf/sip_profiles/external.xml.tmpl` | Trunk profili şablonu |
| `freeswitch/conf/dialplan/default.xml` | Dahili çağrı yönlendirme |
| `freeswitch/conf/dialplan/public.xml` | Trunk'tan gelen çağrılar |
| `freeswitch/scripts/max_calls.lua` | mod_lua ile doğrudan PG sorgusu |
| `xmlapi/app.py` | directory + dialplan XML üretimi (tenant-aware, XML-escaped) |
| `scripts/add-user.sh` | ha1/ha1b hesaplayarak subscriber ekler |
| `scripts/verify-NN-*.sh` | Task başına doğrulama; bu planın "testleri" |
| `README.md` | Tek doküman |

**Test yaklaşımı:** Bu altyapı projesinde birim testin karşılığı, her task için önce başarısız olan bir `scripts/verify-NN-*.sh` yazmak, sonra onu geçirmektir. TDD döngüsü aynen korunur: doğrulamayı yaz → başarısız olduğunu gör → uygula → geçtiğini gör → commit.

---

## Task 1: İskelet, `.env` ve arşivleme

**Files:**
- Create: `.env.example`, `.gitignore`, `docker-compose.yml`, `scripts/verify-01-skeleton.sh`
- Move: 7 markdown → `docs/archive/`, `docker-compose.pgsql.yml` + `init.sql` + `deploy.sh` → `legacy/`

**Interfaces:**
- Produces: `.env` değişkenleri `EXTERNAL_IP`, `SIP_DOMAIN`, `RTP_START`, `RTP_END`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `FS_DB_NAME`, `FS_ESL_PASSWORD`, `TRUNK_*` — sonraki tüm task'lar bu adları kullanır.
- Produces: compose proje adı `voip`, ağ adı `voip_net`, volume adı `voip_pg_data`.

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-01-skeleton.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f .env.example ] || fail ".env.example yok"
[ -f .env ]         || fail ".env yok (cp .env.example .env)"
grep -qx '.env' .gitignore || fail ".env .gitignore'da degil"

for v in EXTERNAL_IP SIP_DOMAIN RTP_START RTP_END POSTGRES_USER \
         POSTGRES_PASSWORD POSTGRES_DB FS_DB_NAME FS_ESL_PASSWORD; do
  grep -q "^${v}=" .env.example || fail "$v .env.example'da yok"
done

grep -q '^version:' docker-compose.yml && fail "compose'da obsolete 'version:' anahtari var"

docker compose config >/dev/null 2>&1 || fail "docker compose config gecersiz"
docker compose config | grep -q 'voip_pg_data' || fail "voip_pg_data volume yok"

for f in QUICK_START.md DEPLOYMENT_PGSQL.md POSTGRESQL_INTEGRATION.md \
         API_MANAGEMENT.md KAMAILIO_CDR_SETUP.md \
         FREESWITCH_POSTGRESQL_SETUP.md FREESWITCH_POSTGRESQL_STATUS.md; do
  [ -f "docs/archive/$f" ] || fail "docs/archive/$f yok"
  [ -f "$f" ] && fail "$f hala kokte (tasinmali, kopyalanmamali)"
done

[ -f legacy/docker-compose.pgsql.yml ] || fail "legacy/docker-compose.pgsql.yml yok"
[ -f legacy/init.sql ]                 || fail "legacy/init.sql yok"

echo "OK: verify-01-skeleton"
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör**

Run: `chmod +x scripts/verify-01-skeleton.sh && ./scripts/verify-01-skeleton.sh`
Expected: FAIL — `.env.example yok`

- [ ] **Step 3: Eski dosyaları taşı**

```bash
mkdir -p docs/archive legacy
git mv QUICK_START.md DEPLOYMENT_PGSQL.md POSTGRESQL_INTEGRATION.md \
       API_MANAGEMENT.md KAMAILIO_CDR_SETUP.md \
       FREESWITCH_POSTGRESQL_SETUP.md FREESWITCH_POSTGRESQL_STATUS.md docs/archive/ 2>/dev/null \
  || mv QUICK_START.md DEPLOYMENT_PGSQL.md POSTGRESQL_INTEGRATION.md \
        API_MANAGEMENT.md KAMAILIO_CDR_SETUP.md \
        FREESWITCH_POSTGRESQL_SETUP.md FREESWITCH_POSTGRESQL_STATUS.md docs/archive/
mv docker-compose.pgsql.yml init.sql deploy.sh legacy/
rm -f freeswitch/build.log
```

Not: dosyaların bir kısmı henüz git'e eklenmemiş (untracked), o yüzden `git mv` başarısız olursa düz `mv` kullanılıyor.

- [ ] **Step 4: `.gitignore` oluştur**

```
.env
freeswitch/build.log
*.log
```

- [ ] **Step 5: `.env.example` oluştur**

```bash
# ============ Ağ ve adresleme ============
# Yerel: makinenin LAN adresi. Sunucu: public IP.
# Bu değer FreeSWITCH'in SDP'de duyurduğu adrestir; yanlışsa ses tek yönlü olur.
EXTERNAL_IP=192.168.1.3
SIP_DOMAIN=voip.local
RTP_START=16384
RTP_END=16403

# ============ PostgreSQL ============
POSTGRES_USER=kamailio
POSTGRES_PASSWORD=change-me-in-env
POSTGRES_DB=kamailio
# FreeSWITCH core DB'si — aynı sunucuda ayrı veritabanı
FS_DB_NAME=freeswitch

# ============ FreeSWITCH ============
FS_ESL_PASSWORD=change-me-esl

# ============ SIP trunk (Task 12'de doldurulur) ============
TRUNK_ENABLED=false
TRUNK_NAME=provider
TRUNK_HOST=
TRUNK_USER=
TRUNK_PASS=
TRUNK_REGISTER=true
TRUNK_DID=
```

- [ ] **Step 6: `docker-compose.yml` oluştur (yalnız postgres)**

```yaml
name: voip

services:
  postgres:
    image: postgres:16
    container_name: voip-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      FS_DB_NAME: ${FS_DB_NAME}
    volumes:
      - ./db/init:/docker-entrypoint-initdb.d:ro
      - voip_pg_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 3s
      retries: 10
    networks: [voip_net]

volumes:
  voip_pg_data:

networks:
  voip_net:
    driver: bridge
```

- [ ] **Step 7: `.env` oluştur ve doğrulamayı çalıştır**

Run:
```bash
cp .env.example .env
mkdir -p db/init
./scripts/verify-01-skeleton.sh
```
Expected: `OK: verify-01-skeleton`

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "chore: single compose skeleton, env-driven config, archive stale docs"
```

---

## Task 2: PostgreSQL şeması, seed ve ikinci veritabanı

**Files:**
- Create: `db/init/01-schema.sql`, `db/init/02-seed.sql`, `db/init/03-freeswitch-db.sh`, `scripts/verify-02-database.sh`
- Source: mevcut `init_full_pgsql.sql` (şema kısmı taşınır, örnek veri ayrılır)

**Interfaces:**
- Consumes: Task 1'in `.env` değişkenleri.
- Produces: `kamailio` veritabanında 9 tablo (`tenants`, `subscriber`, `location`, `dialplan`, `acc`, `missed_calls`, `cdr`, `dispatcher`, `version`) ve 2 view (`fs_directory`, `fs_dialplan`); ayrı `freeswitch` veritabanı.
- Produces: tenant `tenant1.voip.local` (id 1, tenant_code `1234`); kullanıcılar `alice` / `bob`, şifre `alice123` / `bob123`; dispatcher setid 1 → `sip:freeswitch:5060`.
- Produces: `fs_directory` view'ına `tenant_id` kolonu eklenir — CDR'ın tenant'a bağlanabilmesi için gerekli.

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-02-database.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a

fail() { echo "FAIL: $*" >&2; exit 1; }
q()    { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$1" -tAc "$2"; }

docker compose up -d postgres
for i in $(seq 1 30); do
  docker compose exec -T postgres pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1 && break
  sleep 2
done

for t in tenants subscriber location dialplan acc missed_calls cdr dispatcher version; do
  [ "$(q "$POSTGRES_DB" "SELECT to_regclass('public.$t') IS NOT NULL")" = "t" ] \
    || fail "tablo yok: $t"
done

for v in fs_directory fs_dialplan; do
  [ "$(q "$POSTGRES_DB" "SELECT count(*) FROM pg_views WHERE viewname='$v'")" = "1" ] \
    || fail "view yok: $v"
done

# Kamailio'nun bekledigi tablo surumleri
while read -r tbl ver; do
  got=$(q "$POSTGRES_DB" "SELECT table_version FROM version WHERE table_name='$tbl'")
  [ "$got" = "$ver" ] || fail "$tbl surumu $got, beklenen $ver"
done <<'EOF'
subscriber 7
location 9
acc 5
missed_calls 4
dispatcher 4
EOF

[ "$(q "$POSTGRES_DB" "SELECT count(*) FROM tenants WHERE domain='tenant1.voip.local'")" = "1" ] \
  || fail "tenant1 seed edilmemis"
[ "$(q "$POSTGRES_DB" "SELECT count(*) FROM subscriber WHERE username IN ('alice','bob')")" = "2" ] \
  || fail "alice/bob seed edilmemis"
[ "$(q "$POSTGRES_DB" "SELECT count(*) FROM subscriber WHERE ha1 <> '' AND ha1b <> ''")" = "2" ] \
  || fail "ha1/ha1b bos"
[ "$(q "$POSTGRES_DB" "SELECT count(*) FROM dispatcher WHERE setid=1")" -ge 1 ] \
  || fail "dispatcher satiri yok"

# fs_directory tenant_id dondurmeli (CDR icin)
q "$POSTGRES_DB" "SELECT tenant_id FROM fs_directory WHERE \"user\"='alice'" | grep -qE '^[0-9]+$' \
  || fail "fs_directory tenant_id dondurmuyor"

# Ikinci veritabani
[ "$(q postgres "SELECT count(*) FROM pg_database WHERE datname='$FS_DB_NAME'")" = "1" ] \
  || fail "$FS_DB_NAME veritabani yok"

echo "OK: verify-02-database"
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör**

Run: `chmod +x scripts/verify-02-database.sh && ./scripts/verify-02-database.sh`
Expected: FAIL — `tablo yok: tenants` (init dizini boş)

- [ ] **Step 3: Şemayı ayır**

`init_full_pgsql.sql` dosyasını ikiye böl:
- `db/init/01-schema.sql` ← `CREATE TABLE` / `CREATE INDEX` / `CREATE VIEW` / `INSERT INTO version` blokları
- `db/init/02-seed.sql` ← `INSERT INTO tenants` / `INSERT INTO subscriber` / dispatcher / dialplan blokları

Ardından `init_full_pgsql.sql` dosyasını `legacy/` altına taşı.

`01-schema.sql` içindeki `fs_directory` view'ına `tenant_id` ekle — mevcut tanımdaki `s.username AS "user",` satırının hemen ardına:

```sql
    s.tenant_id,
```

- [ ] **Step 4: Seed'i deterministik hale getir**

`db/init/02-seed.sql` içeriği (ha1/ha1b değerleri `md5()` ile veritabanında hesaplanıyor, böylece elle hesaplama hatası olmaz — realm olarak domain kullanılıyor, çünkü Kamailio `use_domain=1` ile çalışacak):

```sql
INSERT INTO tenants (tenant_code, domain, name, company_name, freeswitch_url, max_channels, max_users, active)
VALUES ('1234', 'tenant1.voip.local', 'Tenant 1', 'Test Company A', 'sip:freeswitch:5060', 100, 500, true)
ON CONFLICT (tenant_code) DO NOTHING;

INSERT INTO subscriber (tenant_id, username, domain, password, ha1, ha1b, display_name, max_calls, enabled)
SELECT t.id, v.username, t.domain, v.password,
       md5(v.username || ':' || t.domain || ':' || v.password),
       md5(v.username || '@' || t.domain || ':' || t.domain || ':' || v.password),
       v.display_name, 2, true
FROM tenants t
CROSS JOIN (VALUES
    ('alice', 'alice123', 'Alice'),
    ('bob',   'bob123',   'Bob')
) AS v(username, password, display_name)
WHERE t.tenant_code = '1234'
ON CONFLICT DO NOTHING;

INSERT INTO dispatcher (setid, destination, flags, priority, description)
VALUES (1, 'sip:freeswitch:5060', 0, 0, 'FreeSWITCH node 1')
ON CONFLICT DO NOTHING;
```

- [ ] **Step 5: İkinci veritabanını oluşturan scripti yaz**

`db/init/03-freeswitch-db.sh` — `CREATE DATABASE` transaction içinde çalışamadığı için ve env interpolasyonu gerektiği için `.sql` değil `.sh`:

```bash
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE ${FS_DB_NAME} OWNER ${POSTGRES_USER};
EOSQL
echo "created database ${FS_DB_NAME}"
```

- [ ] **Step 6: Volume'ü sıfırla ve doğrula**

`docker-entrypoint-initdb.d` yalnızca boş bir data dizininde çalışır:

```bash
docker compose down -v
chmod +x db/init/03-freeswitch-db.sh
./scripts/verify-02-database.sh
```
Expected: `OK: verify-02-database`

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(db): split schema and seed, add freeswitch database, expose tenant_id in fs_directory"
```

---

## Task 3: Native arm64 Kamailio image'ı

**Files:**
- Modify: `kamailio/Dockerfile` (tamamen yeniden yazılır)
- Modify: `docker-compose.yml` (kamailio servisi eklenir)
- Create: `scripts/verify-03-kamailio-image.sh`

**Interfaces:**
- Consumes: Task 1'in `.env` değişkenleri.
- Produces: `voip-kamailio` container'ı, host mimarisinde derlenmiş Kamailio 6.0.6; `dispatcher`, `auth_db`, `usrloc`, `registrar`, `db_postgres` modülleri mevcut.

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-03-kamailio-image.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose build kamailio || fail "kamailio image build edilemedi"

HOST_ARCH=$(docker info --format '{{.Architecture}}')
IMG_ARCH=$(docker image inspect voip-kamailio --format '{{.Architecture}}')
case "$HOST_ARCH" in
  aarch64|arm64) EXPECT=arm64 ;;
  x86_64|amd64)  EXPECT=amd64 ;;
  *) fail "bilinmeyen host mimarisi: $HOST_ARCH" ;;
esac
[ "$IMG_ARCH" = "$EXPECT" ] || fail "image mimarisi $IMG_ARCH, beklenen $EXPECT (emulasyon)"

VER=$(docker run --rm --entrypoint kamailio voip-kamailio -v | head -1)
echo "$VER" | grep -q "6\.0\." || fail "beklenmeyen kamailio surumu: $VER"

for m in dispatcher auth_db usrloc registrar db_postgres tm rr; do
  docker run --rm --entrypoint sh voip-kamailio -c \
    "test -f /usr/lib/x86_64-linux-gnu/kamailio/modules/${m}.so || \
     test -f /usr/lib/aarch64-linux-gnu/kamailio/modules/${m}.so" \
    || fail "modul yok: ${m}.so"
done

echo "OK: verify-03-kamailio-image"
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör**

Run: `chmod +x scripts/verify-03-kamailio-image.sh && ./scripts/verify-03-kamailio-image.sh`
Expected: FAIL — compose'da `kamailio` servisi tanımlı değil

- [ ] **Step 3: `kamailio/Dockerfile` yaz**

```dockerfile
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Resmi Kamailio apt deposu — GHCR image'i yalnizca amd64 oldugu icin
# paketten kuruyoruz; deb.kamailio.org bookworm/arm64 sunuyor.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates gnupg curl && \
    curl -fsSL https://deb.kamailio.org/kamailiodebkey.gpg \
        -o /usr/share/keyrings/kamailio.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/kamailio.gpg] http://deb.kamailio.org/kamailio60 bookworm main" \
        > /etc/apt/sources.list.d/kamailio.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        kamailio \
        kamailio-postgres-modules \
        kamailio-extra-modules \
        kamailio-tls-modules && \
    apt-get purge -y curl gnupg && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Tesis/hata ayiklama araclari
RUN apt-get update && \
    apt-get install -y --no-install-recommends iputils-ping netcat-openbsd procps && \
    rm -rf /var/lib/apt/lists/*

COPY kamailio.cfg /etc/kamailio/kamailio.cfg

EXPOSE 5060/udp

# -DD: fork etme, -E: loglari stderr'e (docker logs icin)
CMD ["kamailio", "-DD", "-E", "-f", "/etc/kamailio/kamailio.cfg"]
```

- [ ] **Step 4: Geçici minimal `kamailio.cfg` yaz**

Task 4'te tam config yazılacak; bu adımda image'ın doğrulanabilmesi için sözdizimi geçerli bir iskelet yeterli:

```
#!KAMAILIO
debug=2
log_stderror=yes
fork=no
children=4
listen=udp:0.0.0.0:5060

loadmodule "tm.so"
loadmodule "sl.so"
loadmodule "rr.so"
loadmodule "pv.so"
loadmodule "maxfwd.so"
loadmodule "sanity.so"

request_route {
    if (!mf_process_maxfwd_header("10")) {
        sl_send_reply("483", "Too Many Hops");
        exit;
    }
    sl_send_reply("404", "Not Configured Yet");
    exit;
}
```

- [ ] **Step 5: compose'a kamailio servisini ekle**

`docker-compose.yml` içindeki `services:` altına:

```yaml
  kamailio:
    build: ./kamailio
    image: voip-kamailio
    container_name: voip-kamailio
    restart: unless-stopped
    environment:
      DBURL: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      EXTERNAL_IP: ${EXTERNAL_IP}
      SIP_DOMAIN: ${SIP_DOMAIN}
    ports:
      - "5060:5060/udp"
    depends_on:
      postgres:
        condition: service_healthy
    networks: [voip_net]
```

- [ ] **Step 6: Doğrula**

Run: `./scripts/verify-03-kamailio-image.sh`
Expected: `OK: verify-03-kamailio-image`

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(kamailio): native-arch image from official apt repo, replacing amd64-only GHCR image"
```

---

## Task 4: Kamailio kayıt, kimlik doğrulama ve yönlendirme

**Files:**
- Modify: `kamailio/kamailio.cfg` (tam config)
- Create: `scripts/verify-04-register.sh`

**Interfaces:**
- Consumes: `db/init` seed'indeki `alice`/`bob` (`ha1`, `ha1b`), `dispatcher` setid 1.
- Consumes: `DBURL`, `EXTERNAL_IP` ortam değişkenleri (Task 3).
- Produces: 5060/UDP'de REGISTER + INVITE işleyen proxy; `location` tablosuna kayıt yazar.
- Produces: **FreeSWITCH kaynaklı INVITE'lar `lookup("location")` ile doğrudan aboneye gider**, tekrar dispatcher'a düşmez — bu ayrım olmadan alice→bob sonsuz döngüye girer.

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-04-register.sh` — SIP REGISTER'ı elle üretip yanıtı okur, softphone gerektirmez:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose up -d postgres kamailio
sleep 5

q() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }

# Kamailio ayakta mi
docker compose exec -T kamailio kamctl monitor 1 >/dev/null 2>&1 \
  || docker compose exec -T kamailio kamcmd core.version >/dev/null \
  || fail "kamailio yanit vermiyor"

# Kimlik dogrulamasi olmadan REGISTER 401 almalidir.
# sipsak ile deneniyor; kamailio image'inda kurulu degilse konteynere kur.
docker compose exec -T kamailio sh -c \
  'command -v sipsak >/dev/null || (apt-get update -qq && apt-get install -y -qq sipsak >/dev/null 2>&1)'

OUT=$(docker compose exec -T kamailio sipsak -vv \
        -s "sip:alice@${SIP_DOMAIN}" -H alice 2>&1 || true)
echo "$OUT" | grep -qE '401|407' || fail "kimlik dogrulama zorunlu degil (401 gelmedi) — acik relay riski"

echo "NOT: Basarili REGISTER dogrulamasi Zoiper ile elle yapilir (Step 6)."
echo "OK: verify-04-register (challenge asamasi)"
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör**

Run: `chmod +x scripts/verify-04-register.sh && ./scripts/verify-04-register.sh`
Expected: FAIL — iskelet config her isteğe 404 döndüğü için 401 gelmez

- [ ] **Step 3: Tam `kamailio/kamailio.cfg` yaz**

```
#!KAMAILIO
#
# Kamailio 6.0 — SIP proxy + registrar
# Kimlik dogrulama: subscriber tablosu, digest, use_domain=1 (cok kiracilik)
# Yonlendirme: dispatcher (setid 1) -> FreeSWITCH
#

####### Global #######
debug=2
log_stderror=yes            # docker logs icin
fork=no                     # -DD ile uyumlu
children=4
auto_aliases=no

listen=udp:0.0.0.0:5060 advertise SELF_IP:5060

#!subst "/SELF_IP/$env(EXTERNAL_IP)/"
#!substdef "!DBURL!$env(DBURL)!g"
#!substdef "!FS_HOST!freeswitch!g"

####### Modules #######
loadmodule "tm.so"
loadmodule "sl.so"
loadmodule "rr.so"
loadmodule "pv.so"
loadmodule "maxfwd.so"
loadmodule "textops.so"
loadmodule "siputils.so"
loadmodule "xlog.so"
loadmodule "sanity.so"
loadmodule "ctl.so"
loadmodule "kex.so"
loadmodule "nathelper.so"
loadmodule "db_postgres.so"
loadmodule "auth.so"
loadmodule "auth_db.so"
loadmodule "usrloc.so"
loadmodule "registrar.so"
loadmodule "dispatcher.so"

####### Module params #######
modparam("tm", "fr_timer", 30000)
modparam("tm", "fr_inv_timer", 120000)

modparam("rr", "enable_full_lr", 1)
modparam("rr", "append_fromtag", 0)

# use_domain=1 -> cok kiracilik: alice@tenant1.voip.local ile
# alice@tenant2.voip.local farkli kullanicilardir.
modparam("auth_db", "db_url", "DBURL")
modparam("auth_db", "calculate_ha1", 0)     # ha1 sutunu seed'de hesaplandi
modparam("auth_db", "password_column", "ha1")
modparam("auth_db", "use_domain", 1)
modparam("auth_db", "load_credentials", "")

modparam("usrloc", "db_url", "DBURL")
modparam("usrloc", "db_mode", 2)            # write-back
modparam("usrloc", "use_domain", 1)

modparam("registrar", "method_filtering", 1)
modparam("registrar", "max_expires", 3600)
modparam("registrar", "min_expires", 60)

modparam("dispatcher", "db_url", "DBURL")
modparam("dispatcher", "table_name", "dispatcher")
modparam("dispatcher", "flags", 2)          # inaktif hedefleri atla
modparam("dispatcher", "ds_ping_interval", 30)
modparam("dispatcher", "ds_probing_mode", 1)
modparam("dispatcher", "ds_ping_method", "OPTIONS")

####### Routing #######
request_route {

    if (!mf_process_maxfwd_header("10")) {
        sl_send_reply("483", "Too Many Hops");
        exit;
    }

    if (!sanity_check("1511", "7")) {
        xlog("L_ERR", "Bozuk SIP mesaji: $si:$sp\n");
        exit;
    }

    # NAT
    force_rport();
    if (nat_uac_test("19")) {
        if (is_method("REGISTER")) {
            fix_nated_register();
        } else {
            fix_nated_contact();
        }
    }

    # Dialog ici istekler (ACK, BYE, re-INVITE)
    if (has_totag()) {
        if (loose_route()) {
            t_relay();
            exit;
        }
        if (is_method("ACK")) { exit; }
        sl_send_reply("404", "Not Here");
        exit;
    }

    if (is_method("CANCEL")) {
        if (t_check_trans()) { t_relay(); }
        exit;
    }

    if (!is_method("REGISTER")) {
        record_route();
    }

    route(REGISTRAR);
    route(INVITE);
    exit;
}

# --- Kayit ---
route[REGISTRAR] {
    if (!is_method("REGISTER")) return;

    if (!www_authenticate("$fd", "subscriber")) {
        www_challenge("$fd", "0");
        exit;
    }

    if (!save("location")) {
        sl_reply_error();
        exit;
    }
    xlog("L_INFO", "REGISTER ok: $fu ($si:$sp)\n");
    exit;
}

# --- Cagri kurulumu ---
route[INVITE] {
    if (!is_method("INVITE")) return;

    # FreeSWITCH'ten gelen INVITE: kayitli aboneye dogrudan gonder.
    # Bu ayrim olmazsa cagri tekrar dispatcher'a dusup dongu olusur.
    if (src_ip == FS_HOST) {
        if (!lookup("location")) {
            xlog("L_WARN", "Kayitli degil: $ru\n");
            sl_send_reply("404", "User Not Found");
            exit;
        }
        t_relay();
        exit;
    }

    # Abone kaynakli INVITE: once kimlik dogrula
    if (!proxy_authenticate("$fd", "subscriber")) {
        proxy_challenge("$fd", "0");
        exit;
    }
    # Kimlik dogrulandi -> From basligi gercekten bu kullaniciya mi ait?
    if (!check_from()) {
        sl_send_reply("403", "From Mismatch");
        exit;
    }

    if (!ds_select_dst("1", "4")) {     # setid 1, round-robin
        sl_send_reply("503", "No Media Server Available");
        exit;
    }
    xlog("L_INFO", "$fu -> $ru, FreeSWITCH: $du\n");

    t_on_failure("FS_FAILOVER");
    if (!t_relay()) {
        sl_reply_error();
    }
    exit;
}

failure_route[FS_FAILOVER] {
    if (t_is_canceled()) { exit; }
    if (t_check_status("5[0-9][0-9]")) {
        if (ds_next_dst()) {
            xlog("L_WARN", "FreeSWITCH failover -> $du\n");
            t_relay();
            exit;
        }
    }
}
```

`check_from()` `siputils` modülünde bulunur ve zaten yüklüdür.

- [ ] **Step 4: Doğrula (challenge aşaması)**

Run:
```bash
docker compose build kamailio && docker compose up -d kamailio
./scripts/verify-04-register.sh
```
Expected: `OK: verify-04-register (challenge asamasi)`

- [ ] **Step 5: Kamailio'nun dispatcher'ı yüklediğini doğrula**

Run: `docker compose exec kamailio kamcmd dispatcher.list`
Expected: `sip:freeswitch:5060` hedefi listede (durumu `Inactive` olabilir; FreeSWITCH henüz ayakta değil)

- [ ] **Step 6: Zoiper ile gerçek REGISTER (elle)**

Zoiper hesap ayarları:
- Domain / Host: `<EXTERNAL_IP>:5060` (örn. `192.168.1.3:5060`)
- Username: `alice`
- Password: `alice123`
- Auth username: `alice`
- Outbound proxy: boş
- Domain (SIP alanı): `tenant1.voip.local`

Doğrula:
```bash
docker compose exec postgres psql -U kamailio -d kamailio \
  -c "SELECT username, domain, contact, expires FROM location;"
```
Expected: `alice | tenant1.voip.local | sip:alice@... | <gelecek bir zaman>`

Ardından şifreyi bilerek yanlış girip Zoiper'ın kayıt olamadığını gör.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(kamailio): enforce digest auth on REGISTER and INVITE, add dispatcher routing with FS loop guard"
```

---

## Task 5: FreeSWITCH image ve başlangıç hatalarının giderilmesi

**Files:**
- Modify: `freeswitch/Dockerfile` (sürüm sabitleme, `gettext-base`, entrypoint)
- Create: `freeswitch/entrypoint.sh`
- Create: `freeswitch/conf/autoload_configs/event_socket.conf.xml`
- Modify: `freeswitch/conf/autoload_configs/modules.conf.xml`
- Modify: `docker-compose.yml` (freeswitch servisi)
- Create: `scripts/verify-05-freeswitch-boot.sh`

**Interfaces:**
- Consumes: `.env` → `EXTERNAL_IP`, `RTP_START`, `RTP_END`, `FS_ESL_PASSWORD`.
- Produces: `voip-freeswitch` container'ı; `fs_cli` **çalışır durumda** (8021/TCP); modül yükleme hatası yok.
- Produces: `freeswitch/entrypoint.sh` — `*.tmpl` uzantılı config şablonlarını `envsubst` ile işleyip aynı adın `.tmpl`siz haline yazar, sonra FreeSWITCH'i başlatır.

**Bu task'ın çözdüğü doğrulanmış hatalar:**
- `mod_event_socket.c:2960 Cannot get information about IP address ::` — container'da IPv6 yok, ESL thread'i ölüyor
- `Error Loading module mod_verto.so` / `mod_signalwire.so` — build'de devre dışılar ama vanilla listede yüklenmeye çalışılıyorlar
- `Failed to set SCHED_FIFO scheduler (Operation not permitted)` — `cap_add: SYS_NICE` ile giderilir

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-05-freeswitch-boot.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

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

for m in mod_pgsql mod_xml_curl mod_cdr_pg_csv mod_lua mod_sofia mod_dptools; do
  $FSCLI "module_exists $m" | grep -q true || fail "modul yuklu degil: $m"
done

echo "OK: verify-05-freeswitch-boot"
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör**

Run: `chmod +x scripts/verify-05-freeswitch-boot.sh && ./scripts/verify-05-freeswitch-boot.sh`
Expected: FAIL — compose'da `freeswitch` servisi yok

- [ ] **Step 3: Dockerfile'da sürümleri sabitle**

`freeswitch/Dockerfile` içinde builder aşamasının başındaki `ARG FS_VERSION=v1.10` satırını değiştir:

```dockerfile
ARG FS_VERSION=v1.10.12
ARG SOFIA_VERSION=v1.13.18
ARG SPANDSP_COMMIT=0d2e6ac65e0e8f53d652665a743015a88bf048d4
ARG LIBKS_VERSION=v2.0.7
```

sofia-sip klonlama adımını sabitlenmiş etiketi kullanacak şekilde değiştir:

```dockerfile
WORKDIR /usr/src/sofia-sip
RUN git clone --branch ${SOFIA_VERSION} --depth 1 \
        https://github.com/freeswitch/sofia-sip.git . && \
    ./bootstrap.sh -j && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig
```

libks klonlama adımını da aynı şekilde `--branch ${LIBKS_VERSION} --depth 1` ile sabitle. spandsp adımı zaten commit ile sabitlenmiş, `${SPANDSP_COMMIT}` değişkenini kullanacak şekilde güncelle.

- [ ] **Step 4: Runtime aşamasına `gettext-base` ekle ve entrypoint bağla**

Runtime aşamasındaki `apt-get install` listesine `gettext-base` ekle (`envsubst` için). Ardından `USER freeswitch` satırından **önce** ekle:

```dockerfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
```

Ve dosya sonundaki `CMD` satırını değiştir:

```dockerfile
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/opt/freeswitch/bin/freeswitch", "-nf", "-nonatmap", "-c"]
```

`-nonat` bayrağı kaldırıldı — `ext-rtp-ip` ile açık adres duyurulacağı için NAT tespiti gerekiyor.

- [ ] **Step 5: `freeswitch/entrypoint.sh` yaz**

```bash
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

exec "$@"
```

- [ ] **Step 6: `event_socket.conf.xml` yaz — IPv6 hatasının düzeltmesi**

`freeswitch/conf/autoload_configs/event_socket.conf.xml.tmpl`:

```xml
<configuration name="event_socket.conf" description="Socket Client">
  <settings>
    <param name="nat-map" value="false"/>
    <!-- "::" container'da IPv6 olmadigi icin bind edilemiyordu;
         mod_event_socket thread'i olup fs_cli baglanamiyordu. -->
    <param name="listen-ip" value="0.0.0.0"/>
    <param name="listen-port" value="8021"/>
    <param name="password" value="${FS_ESL_PASSWORD}"/>
    <param name="apply-inbound-acl" value="loopback.auto"/>
  </settings>
</configuration>
```

- [ ] **Step 7: `modules.conf.xml` yaz — yüklenemeyen modülleri çıkar**

`freeswitch/conf/autoload_configs/modules.conf.xml`:

```xml
<configuration name="modules.conf" description="Modules">
  <modules>
    <!-- Loggers -->
    <load module="mod_console"/>
    <load module="mod_logfile"/>

    <!-- Event handlers -->
    <load module="mod_event_socket"/>
    <load module="mod_cdr_pg_csv"/>

    <!-- Database -->
    <load module="mod_pgsql"/>

    <!-- XML interfaces -->
    <load module="mod_xml_curl"/>

    <!-- Endpoints -->
    <load module="mod_sofia"/>

    <!-- Applications -->
    <load module="mod_commands"/>
    <load module="mod_dptools"/>
    <load module="mod_hash"/>
    <load module="mod_lua"/>

    <!-- Dialplan -->
    <load module="mod_dialplan_xml"/>

    <!-- Codecs -->
    <load module="mod_g711"/>
    <load module="mod_opus"/>

    <!-- File formats -->
    <load module="mod_sndfile"/>
    <load module="mod_tone_stream"/>
    <load module="mod_local_stream"/>

    <!-- mod_verto ve mod_signalwire BILEREK yok:
         build'de devre disi birakildilar, yuklenmeye calisilinca
         "Error Loading module" uretiyorlardi. -->
  </modules>
</configuration>
```

- [ ] **Step 8: compose'a freeswitch servisini ekle**

```yaml
  freeswitch:
    build: ./freeswitch
    image: voip-freeswitch
    container_name: voip-freeswitch
    restart: unless-stopped
    cap_add:
      - SYS_NICE          # SCHED_FIFO / nice hatasinin giderilmesi
    environment:
      EXTERNAL_IP: ${EXTERNAL_IP}
      SIP_DOMAIN: ${SIP_DOMAIN}
      RTP_START: ${RTP_START}
      RTP_END: ${RTP_END}
      FS_ESL_PASSWORD: ${FS_ESL_PASSWORD}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      FS_DB_NAME: ${FS_DB_NAME}
      TRUNK_NAME: ${TRUNK_NAME}
      TRUNK_HOST: ${TRUNK_HOST}
      TRUNK_USER: ${TRUNK_USER}
      TRUNK_PASS: ${TRUNK_PASS}
      TRUNK_REGISTER: ${TRUNK_REGISTER}
      TRUNK_DID: ${TRUNK_DID}
    volumes:
      # autoload_configs ve sip_profiles YAZILABILIR bagli: entrypoint.sh
      # *.tmpl sablonlarini bu dizinlere isleyip yaziyor.
      - ./freeswitch/conf/autoload_configs:/opt/freeswitch/etc/freeswitch/autoload_configs
      - ./freeswitch/conf/sip_profiles:/opt/freeswitch/etc/freeswitch/sip_profiles
      # Sablon icermeyen dizinler salt okunur.
      - ./freeswitch/conf/dialplan:/opt/freeswitch/etc/freeswitch/dialplan:ro
      - ./freeswitch/scripts:/opt/freeswitch/scripts:ro
    ports:
      - "5080:5060/udp"
      - "8021:8021/tcp"
      - "${RTP_START}-${RTP_END}:${RTP_START}-${RTP_END}/udp"
    depends_on:
      postgres:
        condition: service_healthy
    networks: [voip_net]
```

Konteyner `USER freeswitch` (uid 1000) ile çalıştığı için, host'taki `freeswitch/conf/autoload_configs` ve `freeswitch/conf/sip_profiles` dizinlerinin bu kullanıcı tarafından yazılabilir olması gerekir. Linux'ta gerekirse `chmod 777` yerine `chown -R 1000:1000 freeswitch/conf/autoload_configs freeswitch/conf/sip_profiles` uygula; Docker Desktop'ta bind mount izinleri otomatik eşlenir.

- [ ] **Step 9: Doğrula**

Run: `./scripts/verify-05-freeswitch-boot.sh`
Expected: `OK: verify-05-freeswitch-boot`

Not: ilk build 30–60 dakika sürer. Sonraki build'ler katman cache'inden yararlanır.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "fix(freeswitch): bind ESL to IPv4, drop unloadable modules, pin source versions, add env templating"
```

---

## Task 6: FreeSWITCH core DB'sinin PostgreSQL'e taşınması

**Files:**
- Create: `freeswitch/conf/autoload_configs/switch.conf.xml.tmpl`
- Create: `scripts/verify-06-core-db.sh`

**Interfaces:**
- Consumes: Task 2'nin `freeswitch` veritabanı; Task 5'in entrypoint şablon mekanizması.
- Produces: FreeSWITCH iç durumu (`channels`, `calls`, `tasks`, `sofia_reg_internal`, `limit_data`) PostgreSQL'de.
- Produces: RTP port aralığı `${RTP_START}`–`${RTP_END}` olarak sınırlanır.

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-06-core-db.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose up -d freeswitch
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done

qfs() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$FS_DB_NAME" -tAc "$1"; }

# FreeSWITCH acilista kendi tablolarini olusturmus olmali
for t in channels calls tasks; do
  [ "$(qfs "SELECT to_regclass('public.$t') IS NOT NULL")" = "t" ] \
    || fail "core tablo PostgreSQL'de yok: $t (core-db-dsn calismiyor)"
done

# SQLite'a dusmedigini dogrula
docker compose exec -T freeswitch sh -c \
  'test -s /opt/freeswitch/var/db/core.db' \
  && fail "core.db (SQLite) hala yaziliyor — core-db-dsn devrede degil"

# RTP araligi uygulanmis mi
$FSCLI "global_getvar rtp_start_port" | grep -q "^${RTP_START}$" || fail "rtp_start_port yanlis"
$FSCLI "global_getvar rtp_end_port"   | grep -q "^${RTP_END}$"   || fail "rtp_end_port yanlis"

echo "OK: verify-06-core-db"
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör**

Run: `chmod +x scripts/verify-06-core-db.sh && ./scripts/verify-06-core-db.sh`
Expected: FAIL — `core tablo PostgreSQL'de yok: channels`

- [ ] **Step 3: `switch.conf.xml.tmpl` yaz**

```xml
<configuration name="switch.conf" description="Core Configuration">
  <settings>
    <param name="colorize-console" value="false"/>
    <param name="max-sessions" value="1000"/>
    <param name="sessions-per-second" value="30"/>
    <param name="loglevel" value="info"/>

    <!-- Core durumu SQLite yerine PostgreSQL'de.
         Build'de --enable-core-pgsql-support ile derlendi. -->
    <param name="core-db-dsn" value="pgsql://host=postgres port=5432 dbname=${FS_DB_NAME} user=${POSTGRES_USER} password=${POSTGRES_PASSWORD}"/>

    <param name="rtp-start-port" value="${RTP_START}"/>
    <param name="rtp-end-port" value="${RTP_END}"/>
  </settings>
  <variables>
    <variable name="sip_domain" value="${SIP_DOMAIN}"/>
    <variable name="external_ip" value="${EXTERNAL_IP}"/>
    <variable name="global_codec_prefs" value="OPUS,PCMU,PCMA"/>
    <variable name="outbound_codec_prefs" value="OPUS,PCMU,PCMA"/>
  </variables>
</configuration>
```

- [ ] **Step 4: Doğrula**

Run:
```bash
docker compose restart freeswitch
./scripts/verify-06-core-db.sh
```
Expected: `OK: verify-06-core-db`

Eğer `core tablo PostgreSQL'de yok` hatası sürerse: `docker compose logs freeswitch | grep -i "core-db\|dsn\|pgsql"` çıktısına bak. `--enable-core-pgsql-support` derlenmemişse DSN sessizce SQLite'a düşer; bu durumda Dockerfile'ın configure satırında bayrağın var olduğunu doğrula.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(freeswitch): move core state DB to PostgreSQL, constrain RTP port range"
```

---

## Task 7: xmlapi — tenant-aware directory ve dialplan

**Files:**
- Modify: `xmlapi/app.py`
- Create: `freeswitch/conf/autoload_configs/xml_curl.conf.xml.tmpl`
- Modify: `docker-compose.yml` (xmlapi servisi)
- Create: `scripts/verify-07-xmlcurl.sh`

**Interfaces:**
- Consumes: `fs_directory` view (Task 2'de `tenant_id` eklendi), `fs_dialplan` view.
- Produces: `GET/POST /fs/directory` → FreeSWITCH directory XML; `<variable name="tenant_id">` **her zaman** döner (CDR bunu kullanacak).
- Produces: `GET/POST /fs/dialplan` → FreeSWITCH dialplan XML.
- Produces: `GET /health` → `{"status":"ok"}`.

**Bu task'ın düzelttiği mevcut kusurlar:**
- `app.py` XML çıktısını f-string ile üretiyor ve **kaçış yapmıyor**; `display_name` içinde `"` veya `<` olması XML'i bozar. SQL zaten parametreli, orada sorun yok.
- Directory yanıtı **cleartext şifre** döndürüyor. Kamailio kimlik doğrulamayı yaptığı ve FreeSWITCH `auth-calls=false` ile çalışacağı için şifreye ihtiyaç yok; kaldırılıyor.

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-07-xmlcurl.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose up -d xmlapi freeswitch
for i in $(seq 1 30); do
  docker compose exec -T xmlapi curl -sf http://localhost:8080/health >/dev/null 2>&1 && break
  sleep 2
done

D=$(docker compose exec -T xmlapi curl -s -X POST http://localhost:8080/fs/directory \
      -d "user=alice" -d "domain=tenant1.voip.local")

echo "$D" | grep -q '<user id="alice"'            || fail "directory alice dondurmedi"
echo "$D" | grep -q 'name="tenant_id"'            || fail "tenant_id degiskeni yok (CDR icin gerekli)"
echo "$D" | grep -q 'name="password"'             && fail "directory hala cleartext sifre donduruyor"

# XML gecerliligi
echo "$D" | docker compose exec -T xmlapi python3 -c \
  "import sys,xml.dom.minidom; xml.dom.minidom.parseString(sys.stdin.read())" \
  || fail "directory yaniti gecerli XML degil"

# Bilinmeyen kullanici bos belge dondurmeli, 500 degil
U=$(docker compose exec -T xmlapi curl -s -o /dev/null -w "%{http_code}" \
      -X POST http://localhost:8080/fs/directory -d "user=yok" -d "domain=tenant1.voip.local")
[ "$U" = "200" ] || fail "bilinmeyen kullanicida HTTP $U dondu, 200 bekleniyordu"

# XML kacisi: ozel karakter iceren display_name bozmamali
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "UPDATE subscriber SET display_name='A \"B\" & <C>' WHERE username='alice';" >/dev/null
E=$(docker compose exec -T xmlapi curl -s -X POST http://localhost:8080/fs/directory \
      -d "user=alice" -d "domain=tenant1.voip.local")
echo "$E" | docker compose exec -T xmlapi python3 -c \
  "import sys,xml.dom.minidom; xml.dom.minidom.parseString(sys.stdin.read())" \
  || fail "ozel karakterli display_name XML'i bozuyor (kacis yapilmiyor)"
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "UPDATE subscriber SET display_name='Alice' WHERE username='alice';" >/dev/null

# FreeSWITCH tarafindan gorunurluk
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
$FSCLI "xml_locate directory domain tenant1.voip.local" | grep -q "alice" \
  || fail "FreeSWITCH xml_curl uzerinden alice'i goremiyor"

echo "OK: verify-07-xmlcurl"
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör**

Run: `chmod +x scripts/verify-07-xmlcurl.sh && ./scripts/verify-07-xmlcurl.sh`
Expected: FAIL — compose'da `xmlapi` servisi yok

- [ ] **Step 3: `xmlapi/app.py` directory fonksiyonunu yeniden yaz**

Mevcut `directory()` fonksiyonunu tümüyle değiştir. `xml.sax.saxutils.quoteattr` her değeri kaçırır ve tırnakları kendisi ekler:

```python
from xml.sax.saxutils import quoteattr

EMPTY_XML = (
    '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
    '<document type="freeswitch/xml">\n'
    '  <section name="result">\n'
    '    <result status="not found"/>\n'
    '  </section>\n'
    '</document>'
)


def _attr(value):
    """XML oznitelik degeri — tirnaklar dahil, kacisli."""
    return quoteattr('' if value is None else str(value))


@app.route('/fs/directory', methods=['GET', 'POST'])
def directory():
    params = request.values.to_dict()
    user = params.get('user')
    domain = params.get('domain')

    if not user or not domain:
        logger.warning("directory: user/domain eksik")
        return Response(EMPTY_XML, mimetype='application/xml')

    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT tenant_id, tenant_code, "effective_caller_id_name",
                   "effective_caller_id_number", "dial-string", "max-calls",
                   "codec-prefs", "call-timeout", "vm-enabled",
                   "forward-destination"
            FROM fs_directory
            WHERE "user" = %s AND domain = %s
            """,
            (user, domain),
        )
        row = cur.fetchone()
        cur.close()
        conn.close()
    except Exception as exc:
        logger.error("directory sorgu hatasi: %s", exc)
        return Response(EMPTY_XML, mimetype='application/xml')

    if not row:
        logger.info("directory: bulunamadi %s@%s", user, domain)
        return Response(EMPTY_XML, mimetype='application/xml')

    # Kimlik dogrulamayi Kamailio yapiyor; FreeSWITCH internal profilinde
    # auth-calls=false. Bu yuzden sifre BILEREK dondurulmuyor.
    variables = [
        ('tenant_id', row['tenant_id']),
        ('tenant_code', row['tenant_code']),
        ('effective_caller_id_name', row['effective_caller_id_name']),
        ('effective_caller_id_number', row['effective_caller_id_number']),
        ('max_calls', row['max-calls']),
        ('codec_prefs', row['codec-prefs']),
        ('call_timeout', row['call-timeout']),
        ('voicemail_enabled', row['vm-enabled']),
    ]
    if row['forward-destination']:
        variables.append(('forward_destination', row['forward-destination']))

    var_xml = '\n'.join(
        '          <variable name={} value={}/>'.format(_attr(n), _attr(v))
        for n, v in variables
    )

    xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
        '<document type="freeswitch/xml">\n'
        '  <section name="directory">\n'
        '    <domain name={}>\n'
        '      <user id={}>\n'
        '        <params>\n'
        '          <param name="dial-string" value={}/>\n'
        '        </params>\n'
        '        <variables>\n'
        '{}\n'
        '        </variables>\n'
        '      </user>\n'
        '    </domain>\n'
        '  </section>\n'
        '</document>'
    ).format(_attr(domain), _attr(user), _attr(row['dial-string']), var_xml)

    logger.info("directory ok: %s@%s", user, domain)
    return Response(xml, mimetype='application/xml')
```

`get_db()` fonksiyonunun `psycopg2.extras.RealDictCursor` kullandığını doğrula; kullanmıyorsa `cursor_factory=RealDictCursor` ekle.

- [ ] **Step 4: `dialplan()` fonksiyonunu aynı kaçış yaklaşımıyla güncelle**

`dialplan()` içindeki tüm f-string XML üretimini `_attr()` kullanacak şekilde değiştir. `actions` alanı ham XML fragment olduğu için kaçırılmaz; onun yerine yalnızca veritabanına güvenilen içerik yazılmalıdır — bu kısıtı fonksiyonun docstring'ine yaz:

```python
@app.route('/fs/dialplan', methods=['GET', 'POST'])
def dialplan():
    """
    FreeSWITCH dialplan lookup.

    GUVENLIK NOTU: dialplan.actions sutunu ham XML fragment olarak
    gomulur, kacirilmaz. Bu sutuna yalnizca yonetici tarafindan
    dogrulanmis icerik yazilmalidir.
    """
```

- [ ] **Step 5: `xml_curl.conf.xml.tmpl` yaz**

```xml
<configuration name="xml_curl.conf" description="cURL XML Gateway">
  <bindings>
    <binding name="directory">
      <param name="gateway-url" value="http://xmlapi:8080/fs/directory" bindings="directory"/>
      <param name="disable-100-continue" value="true"/>
      <param name="timeout" value="5"/>
    </binding>
    <binding name="dialplan">
      <param name="gateway-url" value="http://xmlapi:8080/fs/dialplan" bindings="dialplan"/>
      <param name="disable-100-continue" value="true"/>
      <param name="timeout" value="5"/>
    </binding>
  </bindings>
</configuration>
```

`gateway-credentials` bilerek yok: xmlapi yalnızca `voip_net` üzerinden erişilebilir ve dışarıya port yayınlamaz.

- [ ] **Step 6: compose'a xmlapi servisini ekle**

```yaml
  xmlapi:
    build: ./xmlapi
    image: voip-xmlapi
    container_name: voip-xmlapi
    restart: unless-stopped
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [voip_net]
```

`freeswitch` servisinin `depends_on` bloğuna ekle:

```yaml
      xmlapi:
        condition: service_healthy
```

- [ ] **Step 7: Doğrula**

Run:
```bash
docker compose build xmlapi && docker compose up -d
./scripts/verify-07-xmlcurl.sh
```
Expected: `OK: verify-07-xmlcurl`

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(xmlapi): escape XML output, expose tenant_id, stop returning cleartext passwords"
```

---

## Task 8: SIP profilleri, dialplan ve echo testi

**Files:**
- Create: `freeswitch/conf/sip_profiles/internal.xml.tmpl`
- Create: `freeswitch/conf/autoload_configs/acl.conf.xml.tmpl`
- Create: `freeswitch/conf/dialplan/default.xml`
- Create: `scripts/verify-08-echo.sh`

**Interfaces:**
- Consumes: Task 4'ün Kamailio yönlendirmesi, Task 6'nın `${EXTERNAL_IP}` / RTP aralığı.
- Produces: `internal` SIP profili — `auth-calls=false`, ACL ile Kamailio'ya güven, `ext-sip-ip`/`ext-rtp-ip` = `${EXTERNAL_IP}`, `outbound-proxy` = Kamailio.
- Produces: `default` dialplan bağlamı; `9999` echo testi; kullanıcıdan kullanıcıya köprüleme.
- Produces: her çağrıda `tenant_id` kanal değişkeni set edilir (Task 10'un CDR'ı buna bağlı).

**Medya tasarımının kanıtı bu task'tadır.** Echo testinde ses geri gelmiyorsa `ext-rtp-ip` yanlıştır.

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-08-echo.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose up -d
FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done

# Profil ayakta ve dogru adresi duyuruyor mu
$FSCLI "sofia status profile internal" | grep -q "RUNNING" \
  || fail "internal profili calismiyor"
$FSCLI "sofia status profile internal" | grep -q "${EXTERNAL_IP}" \
  || fail "internal profili ${EXTERNAL_IP} duyurmuyor — ses tek yonlu olur"

# Kimlik dogrulama FreeSWITCH'te KAPALI olmali (Kamailio yapiyor)
$FSCLI "sofia status profile internal" | grep -qi "AUTH-CALLS.*false" \
  || echo "UYARI: auth-calls durumu dogrulanamadi, profil XML'ini elle kontrol et"

# Dialplan 9999'u cozebiliyor mu (cagri kurmadan)
$FSCLI "xml_locate dialplan context default" | grep -q "9999" \
  || fail "dialplan'da 9999 echo extension'i yok"

# Sunucu tarafli cagri ile echo'yu dogrula (softphone gerektirmez)
UUID=$($FSCLI "originate {origination_caller_id_number=verify,ignore_early_media=true}loopback/9999/default &park()" \
        2>&1 | grep -oE '[0-9a-f-]{36}' | head -1) \
  || fail "originate basarisiz"
sleep 3
$FSCLI "uuid_exists $UUID" | grep -q true || fail "echo cagrisi ayakta kalmadi"
$FSCLI "uuid_kill $UUID" >/dev/null

echo "OK: verify-08-echo (sinyalizasyon)"
echo "NOT: cift yonlu ses dogrulamasi Zoiper ile elle yapilir (Step 6)."
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör**

Run: `chmod +x scripts/verify-08-echo.sh && ./scripts/verify-08-echo.sh`
Expected: FAIL — `internal profili calismiyor`

- [ ] **Step 3: `acl.conf.xml.tmpl` yaz**

```xml
<configuration name="acl.conf" description="Network Lists">
  <network-lists>
    <!-- Kimlik dogrulamayi Kamailio yapiyor; FreeSWITCH'in internal
         profili auth-calls=false ile calisiyor. Bu ACL TEK savunma
         hattidir — internal profil disariya acilmamalidir. -->
    <list name="trusted" default="deny">
      <node type="allow" cidr="172.16.0.0/12"/>   <!-- docker bridge -->
      <node type="allow" cidr="127.0.0.0/8"/>
    </list>
  </network-lists>
</configuration>
```

- [ ] **Step 4: `internal.xml.tmpl` yaz**

```xml
<profile name="internal">
  <settings>
    <param name="sip-port" value="5060"/>
    <param name="context" value="default"/>
    <param name="dialplan" value="XML"/>
    <param name="rtp-ip" value="$${local_ip_v4}"/>
    <param name="sip-ip" value="$${local_ip_v4}"/>

    <!-- Docker bridge arkasindaki container'in kendi IP'si disaridan
         erisilemez; SDP'de bu adres duyurulur. Yanlissa ses tek yonlu olur. -->
    <param name="ext-rtp-ip" value="${EXTERNAL_IP}"/>
    <param name="ext-sip-ip" value="${EXTERNAL_IP}"/>

    <!-- Kimlik dogrulama Kamailio'da; burada ACL ile guven. -->
    <param name="auth-calls" value="false"/>
    <param name="apply-inbound-acl" value="trusted"/>

    <!-- FreeSWITCH kayitlari bilmez, Kamailio bilir. Giden tum
         istekler Kamailio'ya gider; Kamailio lookup("location") yapar. -->
    <param name="outbound-proxy" value="sip:kamailio:5060"/>

    <param name="aggressive-nat-detection" value="true"/>
    <param name="apply-nat-acl" value="trusted"/>
    <param name="inbound-codec-prefs" value="$${global_codec_prefs}"/>
    <param name="outbound-codec-prefs" value="$${outbound_codec_prefs}"/>
    <param name="inbound-late-negotiation" value="true"/>
    <param name="rtp-timeout-sec" value="300"/>
    <param name="rtp-hold-timeout-sec" value="1800"/>
  </settings>
</profile>
```

- [ ] **Step 5: `default.xml` dialplan yaz**

Mevcut dosya `<include><context>` sarmalayıcısı olmadan `<extension>` ile başlıyordu ve hiç yüklenmiyordu. Ayrıca içindeki `<action application="pgsql" .../>` **var olmayan bir uygulamadır** — CDR Task 10'da `mod_cdr_pg_csv` ile yapılacak.

```xml
<include>
  <context name="default">

    <!-- Her cagrida tenant_id garanti altina alinir.
         Directory'den gelen kullanicilarda xmlapi set eder;
         gelmeyenlerde (ornegin trunk) burada varsayilan atanir.
         CDR INSERT'i bu degiskene bagli — bos kalirsa INSERT patlar. -->
    <extension name="tenant-default" continue="true">
      <condition field="${tenant_id}" expression="^$">
        <action application="set" data="tenant_id=1"/>
      </condition>
    </extension>

    <extension name="echo-test">
      <condition field="destination_number" expression="^9999$">
        <action application="answer"/>
        <action application="sleep" data="500"/>
        <action application="echo"/>
      </condition>
    </extension>

    <extension name="tone-test">
      <condition field="destination_number" expression="^9998$">
        <action application="answer"/>
        <action application="playback" data="tone_stream://%(2000,4000,440,480);loops=10"/>
        <action application="hangup"/>
      </condition>
    </extension>

    <!-- Kullanicidan kullaniciya: FreeSWITCH kayitlari bilmedigi icin
         cagri Kamailio'ya geri gonderilir (profil outbound-proxy'si),
         Kamailio lookup("location") ile aboneye ulastirir. -->
    <extension name="local-user">
      <condition field="destination_number" expression="^(\d{2,7})$">
        <action application="set" data="call_timeout=30"/>
        <action application="set" data="hangup_after_bridge=true"/>
        <action application="bridge" data="sofia/internal/$1@${domain_name}"/>
      </condition>
    </extension>

  </context>
</include>
```

- [ ] **Step 6: Doğrula**

Run:
```bash
docker compose restart freeswitch
./scripts/verify-08-echo.sh
```
Expected: `OK: verify-08-echo (sinyalizasyon)`

- [ ] **Step 7: Zoiper ile çift yönlü ses (elle) — medya tasarımının kanıtı**

Task 4 Step 6'daki hesapla kayıtlı Zoiper'dan `9999` ara.

Beklenen: konuştuğunda sesini geri duyuyorsun.

Ses gelmiyorsa sırayla kontrol et:
```bash
# SDP'de duyurulan adres dogru mu
docker compose exec freeswitch fs_cli -p "$FS_ESL_PASSWORD" -x "sofia status profile internal" | grep -i ext

# RTP paketleri geliyor mu
docker compose exec freeswitch fs_cli -p "$FS_ESL_PASSWORD" -x "show channels"

# SIP akisini izle
docker run --rm --network voip_voip_net -it sipcapture/sngrep -d any
```
En sık neden: `.env` içindeki `EXTERNAL_IP` makinenin gerçek LAN adresi değil.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(freeswitch): internal profile with ACL trust and external media address, working dialplan"
```

---

## Task 9: Uçtan uca kullanıcıdan kullanıcıya çağrı

**Files:**
- Create: `scripts/verify-09-user-to-user.sh`
- Modify: `kamailio/kamailio.cfg` (gerekirse `src_ip` eşleşmesi düzeltmesi)

**Interfaces:**
- Consumes: Task 4 (Kamailio lookup dalı), Task 8 (FreeSWITCH bridge + outbound-proxy).
- Produces: alice → bob çağrısı; iki kayıtlı abone arasında çift yönlü ses.

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-09-user-to-user.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }

REG=$(q "SELECT count(*) FROM location WHERE username IN ('alice','bob') AND expires > NOW()")
[ "$REG" = "2" ] || fail "alice ve bob'un ikisi de kayitli degil (bulunan: $REG) — iki softphone kaydet"

# Kamailio FS kaynakli INVITE'i dogru daldan gecirmeli.
docker compose exec -T kamailio kamcmd dispatcher.list | grep -q "sip:freeswitch:5060" \
  || fail "dispatcher hedefi yok"
docker compose exec -T kamailio kamcmd dispatcher.list | grep -qi "active" \
  || fail "dispatcher hedefi aktif degil — FreeSWITCH OPTIONS ping'ine yanit vermiyor"

echo "OK: verify-09-user-to-user (onkosullar)"
echo "NOT: cagri dogrulamasi iki Zoiper ile elle yapilir (Step 3)."
```

- [ ] **Step 2: Çalıştır**

Run: `chmod +x scripts/verify-09-user-to-user.sh && ./scripts/verify-09-user-to-user.sh`
Expected: İki softphone kayıtlı değilse FAIL; kaydettikten sonra OK

- [ ] **Step 3: İki softphone ile çağrı (elle)**

İkinci bir cihazda (telefon, aynı WiFi) veya ikinci bir softphone'da `bob` / `bob123` ile kayıt ol. alice'ten `bob` ara.

Beklenen: bob'un telefonu çalar, cevaplayınca çift yönlü ses.

- [ ] **Step 4: Döngü olmadığını doğrula**

Çağrı sırasında:
```bash
docker compose exec freeswitch fs_cli -p "$FS_ESL_PASSWORD" -x "show channels count"
```
Expected: `2 total` (a-leg + b-leg). Sayı sürekli artıyorsa Kamailio'nun `src_ip == FS_HOST` dalı eşleşmiyor demektir.

Eşleşmiyorsa: Kamailio içinden FreeSWITCH'in gerçek IP'sini öğren ve `src_ip` karşılaştırmasını ona göre düzelt:
```bash
docker compose exec kamailio getent hosts freeswitch
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test: verify end-to-end user-to-user call routing without loops"
```

---

## Task 10: CDR'ın PostgreSQL'e yazılması

**Files:**
- Create: `freeswitch/conf/autoload_configs/cdr_pg_csv.conf.xml.tmpl`
- Create: `scripts/verify-10-cdr.sh`

**Interfaces:**
- Consumes: `cdr` tablosu (Task 2), `tenant_id` kanal değişkeni (Task 8).
- Produces: her tamamlanan çağrı için `kamailio.cdr` tablosunda bir satır.

`<schema>` bloğu `cdr` tablosunun kolonlarına **birebir** uymalıdır; `mod_cdr_pg_csv` INSERT ifadesini bu listeden üretir. `id` ve `created_at` kolonları veritabanı tarafından doldurulduğu için listeye dahil edilmez.

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-10-cdr.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }

FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
docker compose up -d
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done

$FSCLI "module_exists mod_cdr_pg_csv" | grep -q true || fail "mod_cdr_pg_csv yuklu degil"

BEFORE=$(q "SELECT count(*) FROM cdr")

# 9998 tone testi kendini kapatir; CDR uretmeli.
$FSCLI "originate {origination_caller_id_number=cdrtest,tenant_id=1}loopback/9998/default &sleep(4000)" >/dev/null 2>&1 || true
sleep 8

AFTER=$(q "SELECT count(*) FROM cdr")
[ "$AFTER" -gt "$BEFORE" ] || fail "CDR satiri olusmadi ($BEFORE -> $AFTER)"

# Zorunlu alanlar dolu mu
[ "$(q "SELECT count(*) FROM cdr WHERE uuid IS NULL")" = "0" ]      || fail "uuid bos CDR var"
[ "$(q "SELECT count(*) FROM cdr WHERE tenant_id IS NULL")" = "0" ] || fail "tenant_id bos CDR var"
[ "$(q "SELECT count(*) FROM cdr WHERE hangup_cause IS NULL")" = "0" ] || fail "hangup_cause bos"

# Basarisiz INSERT'ler burada birikir
LEFT=$(docker compose exec -T freeswitch sh -c \
  'ls /opt/freeswitch/var/log/freeswitch/cdr-pg-csv/*.csv 2>/dev/null | wc -l' | tr -d ' ')
[ "$LEFT" = "0" ] || fail "$LEFT adet CDR PostgreSQL'e yazilamayip diske dustu — sema uyusmuyor"

echo "OK: verify-10-cdr"
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör**

Run: `chmod +x scripts/verify-10-cdr.sh && ./scripts/verify-10-cdr.sh`
Expected: FAIL — `CDR satiri olusmadi`

- [ ] **Step 3: `cdr_pg_csv.conf.xml.tmpl` yaz**

```xml
<configuration name="cdr_pg_csv.conf" description="CDR PostgreSQL">
  <settings>
    <param name="db-info" value="host=postgres port=5432 dbname=${POSTGRES_DB} user=${POSTGRES_USER} password=${POSTGRES_PASSWORD}"/>
    <param name="db-table" value="cdr"/>
    <!-- PostgreSQL'e yazilamayan kayitlar buraya duser; bos olmali. -->
    <param name="log-dir" value="/opt/freeswitch/var/log/freeswitch/cdr-pg-csv"/>
    <param name="rotate-on-hup" value="true"/>
  </settings>

  <!-- Sutun listesi cdr tablosuyla birebir uyusmalidir.
       id ve created_at veritabani tarafindan doldurulur. -->
  <schema>
    <field name="tenant_id"              var="tenant_id"              quote="false"/>
    <field name="uuid"                   var="uuid"                   quote="true"/>
    <field name="caller_id_name"         var="caller_id_name"         quote="true"/>
    <field name="caller_id_number"       var="caller_id_number"       quote="true"/>
    <field name="destination_number"     var="destination_number"     quote="true"/>
    <field name="context"                var="context"                quote="true"/>
    <field name="start_stamp"            var="start_stamp"            quote="true"/>
    <field name="end_stamp"              var="end_stamp"              quote="true"/>
    <!-- answer_stamp DEGIL: cevaplanmayan cagrida bos string olur ve
         TIMESTAMP kolonuna '' yazilamaz (INSERT patlar). answer_epoch
         her zaman sayidir; cevaplanmadiysa 0. Bkz. Step 4. -->
    <field name="answer_epoch"           var="answer_epoch"           quote="false"/>
    <field name="duration"               var="duration"               quote="false"/>
    <field name="billsec"                var="billsec"                quote="false"/>
    <field name="hangup_cause"           var="hangup_cause"           quote="true"/>
    <field name="sip_hangup_disposition" var="sip_hangup_disposition" quote="true"/>
    <field name="read_codec"             var="read_codec"             quote="true"/>
    <field name="write_codec"            var="write_codec"            quote="true"/>
    <field name="remote_media_ip"        var="remote_media_ip"        quote="true"/>
  </schema>
</configuration>
```

- [ ] **Step 4: `answer_epoch` kolonunu şemaya ekle**

Cevaplanmayan çağrıda `${answer_stamp}` boş stringdir ve `TIMESTAMP` kolonuna `''` yazılamaz — `mod_cdr_pg_csv` ürettiği INSERT'te hata alır ve kaydı diske düşürür. `${answer_epoch}` ise her zaman sayıdır (cevaplanmadıysa `0`), bu yüzden `BIGINT` kolona güvenle yazılır.

`db/init/01-schema.sql` içindeki `cdr` tablosu tanımında `end_stamp TIMESTAMP,` satırının hemen ardına ekle:

```sql
    answer_epoch BIGINT DEFAULT 0,                    -- 0 = cevaplanmadi
```

Mevcut bir veritabanı varsa migrasyon:

```bash
docker compose exec -T postgres psql -U kamailio -d kamailio -c \
  "ALTER TABLE cdr ADD COLUMN IF NOT EXISTS answer_epoch BIGINT DEFAULT 0;"
```

`answer_stamp` kolonu tabloda kalır ve `NULL` olur; okunabilir zaman damgası gerekirse `answer_epoch`'tan türetilir:

```sql
SELECT to_timestamp(answer_epoch) FROM cdr WHERE answer_epoch > 0;
```

- [ ] **Step 5: Doğrula**

Run:
```bash
docker compose restart freeswitch
./scripts/verify-10-cdr.sh
```
Expected: `OK: verify-10-cdr`

Başarısız INSERT'ler `cdr-pg-csv/*.csv` altında birikir; hata mesajı için `docker compose logs freeswitch | grep -i cdr`.

- [ ] **Step 6: Gerçek çağrıyla doğrula**

Zoiper'dan `9999`'u ara, kapat, sonra:
```bash
docker compose exec postgres psql -U kamailio -d kamailio \
  -c "SELECT tenant_id, caller_id_number, destination_number, duration, billsec, hangup_cause FROM cdr ORDER BY id DESC LIMIT 5;"
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(freeswitch): write CDRs directly to PostgreSQL with tenant attribution"
```

---

## Task 11: mod_lua ile doğrudan PostgreSQL sorgusu

**Files:**
- Create: `freeswitch/scripts/max_calls.lua`
- Modify: `freeswitch/conf/dialplan/default.xml`
- Modify: `docker-compose.yml` (scripts mount'u — Task 5'te eklendi, doğrula)
- Create: `scripts/verify-11-maxcalls.sh`

**Interfaces:**
- Consumes: `subscriber.max_calls` (seed'de alice/bob için `2`), `mod_pgsql` veritabanı arayüzü, core DB (`limit` uygulamasının `db` arka ucu).
- Produces: `max_calls.lua` — çağıran kullanıcının eşzamanlı çağrı limitini PostgreSQL'den okur ve `limit` uygulamasıyla uygular.

**Neden Lua:** `mod_pgsql` bir veritabanı *arayüzü* modülüdür, dialplan uygulaması sağlamaz. Eski `default.xml`'deki `<action application="pgsql" .../>` bu yüzden hiç çalışmadı. FreeSWITCH'ten doğrudan SQL çalıştırmanın desteklenen yolu `freeswitch.Dbh` nesnesidir.

**Kapsam kısıtı:** Doğrudan SQL yalnızca bu tek senaryoda kullanılır. Dialplan'a SQL yaymak bakımı zorlaştırır ve ihtiyaçların çoğunu `xml_curl` zaten karşılar.

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-11-maxcalls.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
docker compose up -d
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done

$FSCLI "module_exists mod_lua" | grep -q true || fail "mod_lua yuklu degil"

# Script dogrudan calisip PostgreSQL'den deger okuyabiliyor mu
OUT=$($FSCLI "lua max_calls.lua alice tenant1.voip.local" 2>&1)
echo "$OUT" | grep -qE '(^|[^0-9])2([^0-9]|$)' \
  || fail "max_calls.lua alice icin 2 dondurmedi. Cikti: $OUT"

# Bilinmeyen kullanicida varsayilana dusmeli, hata vermemeli
OUT2=$($FSCLI "lua max_calls.lua yokboyle tenant1.voip.local" 2>&1)
echo "$OUT2" | grep -qiE 'error|traceback' \
  && fail "bilinmeyen kullanicida Lua hatasi: $OUT2"

# limit uygulamasinin arka ucu core DB (PostgreSQL) olmali
[ "$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$FS_DB_NAME" -tAc \
     "SELECT to_regclass('public.limit_data') IS NOT NULL")" = "t" ] \
  || fail "limit_data tablosu PostgreSQL'de yok — limit db arka ucu devrede degil"

echo "OK: verify-11-maxcalls"
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör**

Run: `chmod +x scripts/verify-11-maxcalls.sh && ./scripts/verify-11-maxcalls.sh`
Expected: FAIL — `max_calls.lua alice icin 2 dondurmedi`

- [ ] **Step 3: `freeswitch/scripts/max_calls.lua` yaz**

```lua
-- max_calls.lua
--
-- Cagiran kullanicinin subscriber.max_calls degerini PostgreSQL'den okur.
-- mod_pgsql'in veritabani arayuzu uzerinden dogrudan SQL — FreeSWITCH'te
-- ad-hoc sorgu calistirmanin desteklenen tek yolu budur.
--
-- Kullanim (dialplan):  <action application="lua" data="max_calls.lua ${sip_from_user} ${domain_name}"/>
-- Kullanim (CLI):       lua max_calls.lua alice tenant1.voip.local

local DEFAULT_MAX = 1

local user   = argv[1]
local domain = argv[2]

local function log(level, msg)
    freeswitch.consoleLog(level, "[max_calls] " .. msg .. "\n")
end

if not user or not domain then
    log("warning", "user/domain eksik, varsayilan kullaniliyor")
    if session then session:setVariable("user_max_calls", tostring(DEFAULT_MAX)) end
    return
end

local dsn = string.format(
    "pgsql://host=%s port=%s dbname=%s user=%s password=%s",
    os.getenv("POSTGRES_HOST") or "postgres",
    os.getenv("POSTGRES_PORT") or "5432",
    os.getenv("POSTGRES_DB")   or "kamailio",
    os.getenv("POSTGRES_USER") or "kamailio",
    os.getenv("POSTGRES_PASSWORD") or ""
)

local max_calls = DEFAULT_MAX
local dbh = freeswitch.Dbh(dsn)

if not dbh:connected() then
    log("err", "PostgreSQL baglantisi kurulamadi, varsayilan kullaniliyor")
else
    -- Parametreli sorgu Lua Dbh API'sinde yok; degerler escape ediliyor.
    local safe_user   = user:gsub("'", "''")
    local safe_domain = domain:gsub("'", "''")
    local sql = string.format(
        "SELECT max_calls FROM subscriber WHERE username = '%s' AND domain = '%s' AND enabled = true LIMIT 1",
        safe_user, safe_domain
    )
    dbh:query(sql, function(row)
        max_calls = tonumber(row.max_calls) or DEFAULT_MAX
    end)
    dbh:release()
end

log("info", string.format("%s@%s -> max_calls=%d", user, domain, max_calls))

if session then
    session:setVariable("user_max_calls", tostring(max_calls))
else
    -- CLI'den calistirildiginda degeri yazdir (dogrulama scripti bunu okur)
    freeswitch.consoleLog("info", tostring(max_calls) .. "\n")
end
```

`POSTGRES_HOST` ve `POSTGRES_PORT` `docker-compose.yml`'deki `freeswitch` servisinin `environment` bloğunda tanımlı değil — ekle:

```yaml
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
```

- [ ] **Step 4: Dialplan'a limit uygulamasını ekle**

`freeswitch/conf/dialplan/default.xml` içinde `local-user` extension'ının `bridge` satırından **önce**:

```xml
        <action application="lua" data="max_calls.lua ${sip_from_user} ${domain_name}"/>
        <!-- 'db' arka ucu core DB'yi (PostgreSQL) kullanir -->
        <action application="limit" data="db user_calls ${sip_from_user} ${user_max_calls}"/>
```

- [ ] **Step 5: Doğrula**

Run:
```bash
docker compose up -d --force-recreate freeswitch
./scripts/verify-11-maxcalls.sh
```
Expected: `OK: verify-11-maxcalls`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(freeswitch): per-user concurrent call limit via direct PostgreSQL query in Lua"
```

---

## Task 12: SIP trunk — giden çağrı

**Files:**
- Create: `freeswitch/conf/sip_profiles/external.xml.tmpl`
- Create: `freeswitch/conf/sip_profiles/external/trunk.xml.tmpl`
- Modify: `freeswitch/conf/dialplan/default.xml`
- Create: `scripts/verify-12-trunk-out.sh`

**Interfaces:**
- Consumes: `.env` → `TRUNK_ENABLED`, `TRUNK_NAME`, `TRUNK_HOST`, `TRUNK_USER`, `TRUNK_PASS`, `TRUNK_REGISTER`.
- Produces: `external` SIP profili (port 5080) ve `${TRUNK_NAME}` gateway'i.
- Produces: `default` bağlamında dış numara kuralı — `+` veya `00` ile başlayan ya da 10+ haneli numaralar trunk'a çıkar.

Sağlayıcıdan bağımsız: yalnızca `.env` değişir. Telnyx Credential Connection için `TRUNK_REGISTER=true`; Twilio Elastic SIP Trunk için `TRUNK_REGISTER=false` ve sağlayıcı tarafında IP yetkilendirmesi.

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-12-trunk-out.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

if [ "${TRUNK_ENABLED}" != "true" ]; then
  echo "ATLANDI: TRUNK_ENABLED=false. Saglayici bilgilerini .env'e girip true yapin."
  exit 0
fi
[ -n "${TRUNK_HOST}" ] || fail "TRUNK_HOST bos"

FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
docker compose up -d
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done

$FSCLI "sofia status profile external" | grep -q "RUNNING" || fail "external profili calismiyor"
$FSCLI "sofia status gateway ${TRUNK_NAME}" | grep -q "${TRUNK_HOST}" \
  || fail "gateway ${TRUNK_NAME} tanimli degil"

if [ "${TRUNK_REGISTER}" = "true" ]; then
  for i in $(seq 1 15); do
    $FSCLI "sofia status gateway ${TRUNK_NAME}" | grep -q "REGED" && break
    sleep 2
  done
  $FSCLI "sofia status gateway ${TRUNK_NAME}" | grep -q "REGED" \
    || fail "gateway saglayiciya register olamadi (durum REGED degil)"
fi

# Dis numara kuralinin dialplan'da cozulebildigini dogrula
$FSCLI "xml_locate dialplan context default" | grep -q "trunk-out" \
  || fail "dialplan'da trunk-out extension'i yok"

echo "OK: verify-12-trunk-out"
echo "NOT: gercek dis arama Step 6'da elle yapilir."
```

- [ ] **Step 2: Çalıştır**

Run: `chmod +x scripts/verify-12-trunk-out.sh && ./scripts/verify-12-trunk-out.sh`
Expected: `ATLANDI` (henüz sağlayıcı yok) — sağlayıcı girildikten sonra FAIL, sonra OK

- [ ] **Step 3: `external.xml.tmpl` yaz**

```xml
<profile name="external">
  <gateways>
    <X-PRE-PROCESS cmd="include" data="external/*.xml"/>
  </gateways>
  <settings>
    <param name="sip-port" value="5080"/>
    <param name="context" value="public"/>
    <param name="dialplan" value="XML"/>
    <param name="rtp-ip" value="$${local_ip_v4}"/>
    <param name="sip-ip" value="$${local_ip_v4}"/>
    <param name="ext-rtp-ip" value="${EXTERNAL_IP}"/>
    <param name="ext-sip-ip" value="${EXTERNAL_IP}"/>
    <param name="auth-calls" value="false"/>
    <param name="inbound-codec-prefs" value="$${global_codec_prefs}"/>
    <param name="outbound-codec-prefs" value="$${outbound_codec_prefs}"/>
    <param name="rtp-timeout-sec" value="300"/>
  </settings>
</profile>
```

- [ ] **Step 4: `external/trunk.xml.tmpl` yaz**

```xml
<include>
  <gateway name="${TRUNK_NAME}">
    <param name="realm" value="${TRUNK_HOST}"/>
    <param name="proxy" value="${TRUNK_HOST}"/>
    <param name="username" value="${TRUNK_USER}"/>
    <param name="password" value="${TRUNK_PASS}"/>
    <param name="register" value="${TRUNK_REGISTER}"/>
    <param name="register-transport" value="udp"/>
    <param name="expire-seconds" value="600"/>
    <param name="retry-seconds" value="30"/>
    <param name="caller-id-in-from" value="true"/>
    <param name="ping" value="30"/>
  </gateway>
</include>
```

`TRUNK_ENABLED=false` iken bu şablon boş `TRUNK_HOST` ile üretilir ve gateway kayıt denemesi yapar. Bunu engellemek için `entrypoint.sh`'a şablon işleme döngüsünden **sonra** ekle:

```bash
# Trunk kapaliyken gateway tanimini devre disi birak
if [ "${TRUNK_ENABLED:-false}" != "true" ]; then
    rm -f "$CONF/sip_profiles/external/trunk.xml"
    echo "entrypoint: TRUNK_ENABLED=false, trunk gateway devre disi"
fi
```

`TRUNK_ENABLED` değişkenini `docker-compose.yml`'deki `freeswitch` servisinin `environment` bloğuna ekle.

- [ ] **Step 5: Dialplan'a giden çağrı kuralı ekle**

`freeswitch/conf/dialplan/default.xml` içine, `local-user` extension'ından **sonra**:

```xml
    <!-- Dis numara: + ile baslayan, 00 ile baslayan veya 10+ haneli -->
    <extension name="trunk-out">
      <condition field="destination_number" expression="^(\+?\d{10,15}|00\d+)$">
        <action application="set" data="effective_caller_id_number=${effective_caller_id_number}"/>
        <action application="set" data="hangup_after_bridge=true"/>
        <action application="bridge" data="sofia/gateway/${TRUNK_NAME_VAR}/$1"/>
      </condition>
    </extension>
```

`${TRUNK_NAME_VAR}` bir FreeSWITCH global değişkenidir; `switch.conf.xml.tmpl`'in `<variables>` bloğuna ekle:

```xml
    <variable name="TRUNK_NAME_VAR" value="${TRUNK_NAME}"/>
```

- [ ] **Step 6: Sağlayıcı bilgisini gir ve gerçek arama yap (elle)**

`.env` dosyasını doldur. Telnyx Credential Connection örneği:
```
TRUNK_ENABLED=true
TRUNK_NAME=telnyx
TRUNK_HOST=sip.telnyx.com
TRUNK_USER=<connection kullanici adi>
TRUNK_PASS=<connection sifresi>
TRUNK_REGISTER=true
```

Sonra:
```bash
docker compose up -d --force-recreate freeswitch
./scripts/verify-12-trunk-out.sh
```

Zoiper'dan bir cep telefonu numarası ara. Beklenen: telefon çalar, çift yönlü ses.

Ses gelmiyorsa sağlayıcının SRTP/TLS zorunlu tutup tutmadığını kontrol et — bu planda TLS/SRTP kapsam dışı.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(trunk): provider-agnostic outbound SIP trunk driven entirely by .env"
```

---

## Task 13: SIP trunk — gelen çağrı

**Files:**
- Create: `freeswitch/conf/dialplan/public.xml`
- Create: `scripts/verify-13-trunk-in.sh`

**Interfaces:**
- Consumes: Task 12'nin `external` profili (context `public`), `.env` → `TRUNK_DID`.
- Produces: `public` bağlamı — `${TRUNK_DID}` numarasına gelen çağrı `alice`'e yönlenir.

Gelen çağrı, `public` bağlamına düşer; oradan `default` bağlamına transfer edilerek dahili yönlendirme yeniden kullanılır. `tenant_id` burada da açıkça set edilir, aksi halde CDR INSERT'i başarısız olur (Task 10).

- [ ] **Step 1: Doğrulama scriptini yaz**

`scripts/verify-13-trunk-in.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a
fail() { echo "FAIL: $*" >&2; exit 1; }

if [ "${TRUNK_ENABLED}" != "true" ] || [ -z "${TRUNK_DID}" ]; then
  echo "ATLANDI: TRUNK_ENABLED=true ve TRUNK_DID dolu olmali."
  exit 0
fi

FSCLI="docker compose exec -T freeswitch fs_cli -p ${FS_ESL_PASSWORD} -x"
docker compose up -d
for i in $(seq 1 45); do $FSCLI "status" >/dev/null 2>&1 && break; sleep 2; done

$FSCLI "xml_locate dialplan context public" | grep -q "did-inbound" \
  || fail "public baglaminda did-inbound extension'i yok"

# DID'in public baglaminda cozuldugunu cagri kurmadan dogrula
$FSCLI "xml_locate dialplan context public" | grep -q "${TRUNK_DID}" \
  || fail "public baglami ${TRUNK_DID} numarasini tanimiyor"

echo "OK: verify-13-trunk-in"
echo "NOT: gercek gelen cagri Step 4'te elle test edilir."
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör**

Run: `chmod +x scripts/verify-13-trunk-in.sh && ./scripts/verify-13-trunk-in.sh`
Expected: FAIL — `public baglaminda did-inbound extension'i yok`

- [ ] **Step 3: `freeswitch/conf/dialplan/public.xml` yaz**

```xml
<include>
  <context name="public">

    <!-- Trunk'tan gelen cagrilarda directory kullanicisi yok,
         bu yuzden tenant_id burada aciklikla set edilir.
         Bos kalirsa CDR INSERT'i basarisiz olur. -->
    <extension name="tenant-inbound" continue="true">
      <condition>
        <action application="set" data="tenant_id=1"/>
        <action application="set" data="domain_name=${SIP_DOMAIN_VAR}"/>
      </condition>
    </extension>

    <extension name="did-inbound">
      <condition field="destination_number" expression="^\+?${TRUNK_DID_VAR}$">
        <action application="set" data="hangup_after_bridge=true"/>
        <action application="transfer" data="alice XML default"/>
      </condition>
    </extension>

    <!-- Tanimsiz DID'ler acikca reddedilir; sessiz dusme olmasin. -->
    <extension name="unknown-did">
      <condition field="destination_number" expression="^.*$">
        <action application="log" data="WARNING Tanimsiz DID: ${destination_number}"/>
        <action application="respond" data="404 Not Found"/>
      </condition>
    </extension>

  </context>
</include>
```

`${TRUNK_DID_VAR}` ve `${SIP_DOMAIN_VAR}` global değişkenlerini `switch.conf.xml.tmpl`'in `<variables>` bloğuna ekle:

```xml
    <variable name="TRUNK_DID_VAR" value="${TRUNK_DID}"/>
    <variable name="SIP_DOMAIN_VAR" value="${SIP_DOMAIN}"/>
```

- [ ] **Step 4: Sağlayıcı tarafında yönlendirmeyi kur ve test et (elle)**

`.env` içine `TRUNK_DID=<satin alinan numara>` yaz ve `docker compose up -d --force-recreate freeswitch` çalıştır.

Sağlayıcı panelinde numarayı bu connection'a bağla:
- **Telnyx (Credential Connection):** numara zaten register olan connection'a düşer, ek ayar gerekmez.
- **Twilio:** Origination URI olarak public erişilebilir bir adres gerekir; NAT arkasındaki yerel kurulumda bu adım çalışmaz — sunucuya kurulduktan sonra test edilmelidir.

Bir cep telefonundan DID'i ara. Beklenen: alice'in Zoiper'ı çalar, cevaplayınca çift yönlü ses.

Ardından CDR'ı doğrula:
```bash
docker compose exec postgres psql -U kamailio -d kamailio \
  -c "SELECT tenant_id, caller_id_number, destination_number, duration, hangup_cause FROM cdr ORDER BY id DESC LIMIT 3;"
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(trunk): inbound DID routing with explicit tenant attribution"
```

---

## Task 14: README, sunucu override'ı ve tam yığın doğrulaması

**Files:**
- Create: `README.md` (mevcut dosya tamamen değiştirilir)
- Create: `docker-compose.host.yml`
- Create: `scripts/verify-all.sh`

**Interfaces:**
- Consumes: Task 1–13'ün tüm doğrulama scriptleri.
- Produces: sıfırdan kurulum talimatı ve tek komutla tam doğrulama.

- [ ] **Step 1: `scripts/verify-all.sh` yaz**

```bash
#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
for s in scripts/verify-[0-9]*.sh; do
  printf '%-40s ' "$(basename "$s")"
  OUT=$("$s" 2>&1)
  RC=$?
  if [ $RC -ne 0 ]; then
    echo "FAIL"; echo "$OUT" | sed 's/^/    /'; FAIL=$((FAIL+1))
  elif echo "$OUT" | grep -q '^ATLANDI'; then
    echo "SKIP"; SKIP=$((SKIP+1))
  else
    echo "PASS"; PASS=$((PASS+1))
  fi
done

echo
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ $FAIL -eq 0 ]
```

- [ ] **Step 2: Çalıştır**

Run: `chmod +x scripts/verify-all.sh && ./scripts/verify-all.sh`
Expected: `FAIL=0` (trunk task'ları sağlayıcı yoksa SKIP)

- [ ] **Step 3: `docker-compose.host.yml` yaz**

```yaml
# Linux sunucuda opsiyonel: RTP icin host ag yigini kullanir,
# Docker NAT katmanini atlar. Docker Desktop'ta CALISMAZ.
#
# Kullanim: docker compose -f docker-compose.yml -f docker-compose.host.yml up -d
services:
  kamailio:
    network_mode: host
    ports: !reset []
  freeswitch:
    network_mode: host
    ports: !reset []
```

`network_mode: host` kullanıldığında servisler birbirini `postgres`/`freeswitch` adlarıyla bulamaz. Bu override'ı kullanırken `.env` içinde bağlantı hedeflerini `127.0.0.1` yapmak gerekir — bunu README'de belirt.

- [ ] **Step 4: `README.md` yaz**

```markdown
# VoIP Stack — Kamailio + FreeSWITCH + PostgreSQL

Kamailio SIP proxy/registrar, FreeSWITCH medya sunucusu ve PostgreSQL'in
tek bir Docker Compose yığınında çalıştığı SIP altyapısı.

## Mimari

Kamailio kimlik doğrulama ve kayıt işlerini yapar, çağrıları dispatcher ile
FreeSWITCH'e dağıtır. FreeSWITCH B2BUA olarak medyayı anchor'lar. Kamailio
medya yoluna girmez, bu yüzden rtpengine yoktur.

FreeSWITCH PostgreSQL'i dört katmanda kullanır:

| Katman | Nerede |
|---|---|
| Core durum DB'si | `freeswitch` veritabanı (`switch.conf.xml` → `core-db-dsn`) |
| Directory + dialplan | `xmlapi` servisi üzerinden `kamailio` veritabanı |
| CDR | `mod_cdr_pg_csv` → `kamailio.cdr` |
| Doğrudan sorgu | `mod_lua` + `freeswitch.Dbh` (eşzamanlı çağrı limiti) |

## Kurulum

```bash
cp .env.example .env
# .env icinde EXTERNAL_IP'yi bu makinenin adresine ayarla
docker compose up -d
./scripts/verify-all.sh
```

`EXTERNAL_IP` en kritik ayardır: FreeSWITCH'in SDP'de duyurduğu adrestir.
Yanlışsa çağrı kurulur ama ses tek yönlü olur.

## Softphone ayarları (Zoiper)

| Alan | Değer |
|---|---|
| Host | `<EXTERNAL_IP>:5060` |
| Username | `alice` |
| Password | `alice123` |
| Domain | `tenant1.voip.local` |

Test numaraları: `9999` echo · `9998` ton · `bob` kullanıcıdan kullanıcıya

## Kullanıcı ekleme

```bash
./scripts/add-user.sh <kullanici> <sifre> <tenant_domain>
```

## SIP trunk

`.env` içinde `TRUNK_*` değişkenlerini doldurup `TRUNK_ENABLED=true` yap,
sonra `docker compose up -d --force-recreate freeswitch`.

Sağlayıcıdan bağımsızdır; register tabanlı (`TRUNK_REGISTER=true`) veya IP
tabanlı (`false`) çalışır.

## Sunucuya kurulum

Aynı yığın, farklı `.env`:

```
EXTERNAL_IP=<public IP>
SIP_DOMAIN=voip.sirket.com
```

DNS'te `voip.sirket.com` kaydını public IP'ye yönlendir. Kod veya config
değişikliği gerekmez.

Linux sunucuda RTP performansı için opsiyonel host-network override'ı:

```bash
docker compose -f docker-compose.yml -f docker-compose.host.yml up -d
```

Bu override kullanıldığında servisler birbirini konteyner adıyla bulamaz;
`.env` içindeki bağlantı hedeflerini `127.0.0.1` yapmak gerekir.

## Bilinen ortam farkı

Docker Desktop (macOS/Windows) yayınlanan portlarda kaynak IP'yi maskeler —
Kamailio istemcinin gerçek IP'sini değil Docker gateway'ini görür. Linux'ta
DNAT gerçek IP'yi korur. Bu testi engellemez, ancak **NAT davranışı yerelde
ve sunucuda birebir aynı görünmez.**

## Hata ayıklama

```bash
docker compose logs -f freeswitch
docker compose exec freeswitch fs_cli -p "$FS_ESL_PASSWORD"
docker compose exec kamailio kamcmd dispatcher.list
docker compose exec postgres psql -U kamailio -d kamailio -c "SELECT * FROM location;"
docker run --rm --network voip_voip_net -it sipcapture/sngrep -d any
```

## Kapsam dışı

TLS/SRTP · Kamailio accounting (`acc`, şema hazır) · voicemail/IVR/konferans ·
ikinci FreeSWITCH node'u (`dispatcher` tablosuna satır eklemek yeterli)

## Dokümanlar

- Tasarım: `docs/superpowers/specs/2026-08-08-voip-stack-pgsql-trunk-design.md`
- Uygulama planı: `docs/superpowers/plans/2026-08-08-voip-stack-pgsql-rebuild.md`
- Eski dokümanlar: `docs/archive/` (geçersiz, tarihsel referans)
```

- [ ] **Step 5: `scripts/add-user.sh` yaz**

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; . ./.env; set +a

if [ $# -ne 3 ]; then
  echo "Kullanim: $0 <kullanici> <sifre> <tenant_domain>" >&2
  echo "Ornek:    $0 carol carol123 tenant1.voip.local" >&2
  exit 1
fi

USER=$1; PASS=$2; DOMAIN=$3

docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<SQL
INSERT INTO subscriber (tenant_id, username, domain, password, ha1, ha1b, display_name, max_calls, enabled)
SELECT t.id, '${USER}', t.domain, '${PASS}',
       md5('${USER}:' || t.domain || ':${PASS}'),
       md5('${USER}@' || t.domain || ':' || t.domain || ':${PASS}'),
       initcap('${USER}'), 2, true
FROM tenants t
WHERE t.domain = '${DOMAIN}';
SQL

echo "Eklendi: ${USER}@${DOMAIN}"
```

- [ ] **Step 6: Tam doğrulama**

Run:
```bash
chmod +x scripts/add-user.sh
docker compose down
docker compose up -d
./scripts/verify-all.sh
```
Expected: `FAIL=0`

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "docs: single README replacing seven contradictory documents, add full-stack verification"
```

---

## Sonraki plan (bu planın kapsamı dışında)

**FreeSWITCH bookworm geçişi.** Task 1–14 yeşile döndükten sonra ayrı bir plan
olarak yazılır. Gerekçe spec §10'da: çalışan bir build'i base image geçişiyle
aynı anda riske atmak iki bağımsız riski birbirine düğümler. Bu plandaki
`scripts/verify-all.sh` o geçişin regresyon testi olur.

Bilinen kırılma noktaları: `libssl1.1` → `libssl3`, `libtiff5` → `libtiff6`,
`libavcodec58` → `libavcodec59`, `libswscale5` → `libswscale6`,
`libvpx6` → `libvpx7`, `liblua5.2-0` paketinin bookworm'da bulunmaması.
Yedek plan: SignalWire resmi apt paketleri (personal access token gerektirir).
