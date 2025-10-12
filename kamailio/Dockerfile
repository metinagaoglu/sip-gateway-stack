FROM --platform=linux/amd64 ghcr.io/kamailio/kamailio:6.0.3-focal

RUN apt-get update && apt-get install -y \
    kamailio-postgres-modules \
    kamailio-redis-modules \
    && rm -rf /var/lib/apt/lists/*

COPY kamailio.cfg /etc/kamailio/kamailio.cfg
COPY dispatcher.list /etc/kamailio/dispatcher.list

# Syntax kontrolü ekle
RUN kamailio -c -f /etc/kamailio/kamailio.cfg || (echo "=== CONFIG ERROR ===" && cat -n /etc/kamailio/kamailio.cfg | grep -A5 -B5 "$(kamailio -c -f /etc/kamailio/kamailio.cfg 2>&1 | grep 'line' | head -1 | sed 's/.*line \([0-9]*\).*/\1/')" && exit 1)

CMD ["kamailio", "-DD", "-E", "-f", "/etc/kamailio/kamailio.cfg"]