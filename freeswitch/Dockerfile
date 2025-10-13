# freeswitch/Dockerfile
FROM safarov/freeswitch

# Custom config dosyalarını /usr/share altına kopyala
# Entrypoint script bunları /etc/freeswitch'e kopyalayacak
COPY conf/ /usr/share/freeswitch/conf/vanilla/

EXPOSE 5060/udp 8021/tcp 16384-16400/udp