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
