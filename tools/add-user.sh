#!/bin/bash
# Kamailio kullanıcı ekleme scripti

# Kullanım kontrolü
if [ $# -lt 2 ]; then
    echo "Kullanım: $0 <username> <password> [domain]"
    echo "Örnek: $0 alice alice123"
    echo "Örnek: $0 bob bob456 kamailio"
    exit 1
fi

USERNAME=$1
PASSWORD=$2
DOMAIN=${3:-kamailio}  # Varsayılan domain: kamailio

# MD5 hash hesaplama (ha1 ve ha1b)
HA1=$(echo -n "${USERNAME}:${DOMAIN}:${PASSWORD}" | md5sum | awk '{print $1}')
HA1B=$(echo -n "${USERNAME}@${DOMAIN}:${DOMAIN}:${PASSWORD}" | md5sum | awk '{print $1}')

# SQL sorgusu
SQL="INSERT INTO subscriber (username, domain, password, ha1, ha1b) 
VALUES ('${USERNAME}', '${DOMAIN}', '${PASSWORD}', '${HA1}', '${HA1B}')
ON CONFLICT (username, domain) 
DO UPDATE SET password='${PASSWORD}', ha1='${HA1}', ha1b='${HA1B}';"

# PostgreSQL'e bağlan ve kullanıcı ekle
docker-compose exec -T postgres psql -U kamailio -d kamailio -c "$SQL"

if [ $? -eq 0 ]; then
    echo "✓ Kullanıcı başarıyla eklendi/güncellendi:"
    echo "  Username: ${USERNAME}"
    echo "  Domain: ${DOMAIN}"
    echo "  Password: ${PASSWORD}"
    echo ""
    echo "SIP Client Ayarları:"
    echo "  Server: localhost:5060"
    echo "  Username: ${USERNAME}"
    echo "  Password: ${PASSWORD}"
    echo "  Domain/Realm: ${DOMAIN}"
else
    echo "✗ Hata: Kullanıcı eklenemedi!"
    exit 1
fi