FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Resmi Kamailio apt deposu — GHCR image'i yalnizca amd64 oldugu icin
# paketten kuruyoruz; deb.kamailio.org bookworm/arm64 sunuyor.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates gnupg curl && \
    curl -fsSL https://deb.kamailio.org/kamailiodebkey.gpg \
        | gpg --dearmor -o /usr/share/keyrings/kamailio.gpg && \
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
# sipsak: verify-04-register.sh REGISTER challenge (401/407) testini yapar.
# Build-time'da imaja gomulu; calisma zamaninda apt-get ile kurulmuyor ki
# konteyner immutable kalsin ve test agdan/paket deposundan bagimsiz olsun.
RUN apt-get update && \
    apt-get install -y --no-install-recommends iputils-ping netcat-openbsd procps sipsak && \
    rm -rf /var/lib/apt/lists/*

COPY kamailio.cfg /etc/kamailio/kamailio.cfg

EXPOSE 5060/udp

# -DD: fork etme, -E: loglari stderr'e (docker logs icin)
CMD ["kamailio", "-DD", "-E", "-f", "/etc/kamailio/kamailio.cfg"]
