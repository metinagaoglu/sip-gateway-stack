# ============================================================================
# AŞAMA 1: DERLEME ORTAMI (Builder)
# ============================================================================
FROM debian:bullseye-slim AS builder

ARG FS_VERSION=v1.10.12
ARG SOFIA_VERSION=v1.13.18
ARG SPANDSP_COMMIT=0d2e6ac65e0e8f53d652665a743015a88bf048d4
ARG LIBKS_VERSION=v2.0.7

ENV DEBIAN_FRONTEND=noninteractive \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig

WORKDIR /usr/src

# Adım 1: Temel derleyici araçları ve tüm bağımlılıkları kur
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential cmake pkg-config \
    git ca-certificates wget curl \
    autoconf automake libtool libtool-bin yasm \
    perl tcl nasm \
    zlib1g-dev libssl-dev libsqlite3-dev libpcre3-dev \
    libspeexdsp-dev libspeex-dev libedit-dev \
    libcurl4-openssl-dev libldns-dev libopus-dev \
    libavformat-dev libswscale-dev libswresample-dev libvpx-dev libavcodec-dev \
    libsndfile1-dev libopusfile-dev \
    libjpeg62-turbo-dev libtiff5-dev \
    libpq-dev libmariadb-dev \
    libncurses-dev libglib2.0-dev \
    liblua5.2-dev libperl-dev \
    uuid-dev xml2 libxml2-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Adım 2: libks (KitSun Signal) - mod_verto ve mod_signalwire için gerekli
# NOT: --depth 1 kullanilamaz; libks'in CMakeLists.txt'i changelog uretmek icin
# etiketten once en az bir commit'e (v2.0.7^) erisim gerektiriyor, sig clone
# --depth 1 bunu kirpip "fatal: Not a valid object name v2.0.7^" ile configure'u
# bozuyor. Tam klon + sabit etiket checkout ediyoruz; surum yine sabit kaliyor.
WORKDIR /usr/src/libks
RUN git clone --branch ${LIBKS_VERSION} \
        https://github.com/signalwire/libks.git . && \
    cmake . && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# Adım 3: Sofia-SIP kütüphanesi
WORKDIR /usr/src/sofia-sip
RUN git clone --branch ${SOFIA_VERSION} --depth 1 \
        https://github.com/freeswitch/sofia-sip.git . && \
    ./bootstrap.sh -j && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# Adım 4: SPANDSP kütüphanesi (FAX ve ses kodlama)
WORKDIR /usr/src/spandsp
RUN git clone https://github.com/freeswitch/spandsp.git . && \
    git reset --hard ${SPANDSP_COMMIT} && \
    ./bootstrap.sh -j && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# Adım 5: FreeSWITCH kaynak kodunu klonla (sabitlenmiş sürüm etiketi, dal değil)
WORKDIR /usr/src/freeswitch
RUN git clone --branch ${FS_VERSION} --depth 1 \
        https://github.com/signalwire/freeswitch.git .

# Adım 6: Bootstrap ve Configure (Modülleri yapılandır)
RUN \
    # PostgreSQL modüllerini etkinleştir
    sed -i 's|#database/mod_pgsql|database/mod_pgsql|' build/modules.conf.in && \
    sed -i 's|#event_handlers/mod_cdr_pg_csv|event_handlers/mod_cdr_pg_csv|' build/modules.conf.in && \
    sed -i 's|#dialplan_tools/mod_dialplan_pgsql|dialplan_tools/mod_dialplan_pgsql|' build/modules.conf.in && \
    \
    # XML Curl modülünü etkinleştir (PostgreSQL directory için gerekli)
    sed -i 's|#xml_int/mod_xml_curl|xml_int/mod_xml_curl|' build/modules.conf.in && \
    \
    # mod_verto'yu etkinleştir (libks kurulu olduğu için çalışacak)
    # mod_signalwire'ı devre dışı bırak (signalwire-client-c kütüphanesi eksik)
    sed -i 's|^applications/mod_signalwire|#applications/mod_signalwire|' build/modules.conf.in && \
    \
    # İstenmeyen modülleri devre dışı bırak
    sed -i 's|^applications/mod_v8|#applications/mod_v8|' build/modules.conf.in && \
    sed -i 's|^formats/mod_v8|#formats/mod_v8|' build/modules.conf.in && \
    sed -i 's|^databases/mod_memcache|#databases/mod_memcache|' build/modules.conf.in && \
    \
    # Bootstrap betiğini çalıştır (configure scriptini oluştur)
    ./bootstrap.sh -j

# Adım 7: Configure komutunu çalıştır
RUN ./configure --prefix=/opt/freeswitch \
    --enable-core-pgsql-support \
    CFLAGS='-Wno-error=deprecated-declarations'

# Adım 8: FreeSWITCH'i derle
RUN make -j$(nproc)

# Adım 9: FreeSWITCH'i kur, vanilla config ve ses dosyalarını kur
RUN make install && \
    make samples && \
    make sounds-install && \
    make moh-install

# ============================================================================
# AŞAMA 2: SON ÇALIŞTIRMA İMAJI (Runtime)
# ============================================================================
FROM debian:bullseye-slim

WORKDIR /opt/freeswitch

# Adım 1: Sadece runtime bağımlılıklarını kur
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl1.1 libsqlite3-0 libpcre3 libspeexdsp1 libspeex1 libedit2 \
    libcurl4 libldns3 libopus0 liblua5.2-0 \
    libavformat58 libswscale5 libswresample3 libvpx6 libavcodec58 \
    libsndfile1 libopusfile0 \
    libjpeg62-turbo libtiff5 \
    libpq5 libmariadb3 \
    libncurses6 libglib2.0-0 \
    libuuid1 libxml2 \
    gettext-base libcap2-bin \
    procps psmisc nano curl iputils-ping netcat-openbsd less && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Adım 2: FreeSWITCH kulllanıcısı ve grubu oluştur
RUN groupadd --gid 1000 freeswitch && \
    useradd --uid 1000 --gid 1000 --home-dir /opt/freeswitch \
    --shell /bin/bash --no-create-home freeswitch

# Adım 3: Builder aşamasından derlenmiş dosyaları kopyala
COPY --from=builder /opt/freeswitch /opt/freeswitch
COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /usr/local/include /usr/local/include

# Adım 4: FreeSWITCH'in kullnadığı dizinleri oluştur
RUN mkdir -p /opt/freeswitch/log \
             /opt/freeswitch/db \
             /opt/freeswitch/recordings \
             /opt/freeswitch/cache && \
    chown -R freeswitch:freeswitch /opt/freeswitch

# Adım 5: Sistem kütüphanelerini güncelle
RUN ldconfig

# Adım 5b: SCHED_FIFO icin dosya capability'si tanimla.
# cap_add: SYS_NICE compose'da bounding set'e ekliyor ama konteyner
# "freeswitch" (uid 1000, root degil) olarak basladigi icin bu capability
# process'in effective/permitted/ambient kumesine hic girmiyor — bounding
# set'te olmasi tek basina yetmiyor. Binary'ye dosya capability'si vererek
# execve sirasinda non-root process'in de bu capability'yi effective olarak
# almasi sagalaniyor.
RUN setcap 'cap_sys_nice=+ep' /opt/freeswitch/bin/freeswitch

# Adım 6: Symlink'ler oluştur (opsiyonel)
RUN ln -sf /opt/freeswitch/bin/freeswitch /usr/bin/freeswitch && \
    ln -sf /opt/freeswitch/bin/fs_cli /usr/bin/fs_cli

# Adım 6b: entrypoint betiğini kur (*.tmpl sablonlarini envsubst ile isler)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# FreeSWITCH kullanıcısına geç (root değil!)
USER freeswitch

# Adım 7: Port'ları aç
EXPOSE 5060/tcp 5060/udp
EXPOSE 5080/tcp 5080/udp
EXPOSE 8021/tcp
EXPOSE 16384-32768/udp

# Adım 8: Sağlık kontrolü
# Shell formunda CALISTIRILIYOR ki $FS_ESL_PASSWORD ortam degiskeni her
# kontrolde interpolate edilsin — sifre burada literal yazilmiyor, compose'un
# "environment:" kismindan geliyor (bkz. docker-compose.yml, .env).
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD fs_cli -p "$FS_ESL_PASSWORD" -x "status" || exit 1

# Adım 9: FreeSWITCH'i başlat
# entrypoint.sh once *.tmpl sablonlarini render eder, sonra CMD'yi exec eder.
# -nonat kaldirildi: ext-rtp-ip ile acik adres duyurulacagi icin NAT tespiti
# gerekiyor (vanilla -nonat NAT otomatik algilamasini tamamen kapatir).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/opt/freeswitch/bin/freeswitch", "-nf", "-nonatmap", "-c"]
