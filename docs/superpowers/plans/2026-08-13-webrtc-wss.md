# WebRTC WSS (Faz 1: tarayıcı → Zoiper) Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tarayıcıdan WebRTC ile `9999` echo'yu ve UDP üzerinde kayıtlı Zoiper'ı (`bob`) arayıp iki yönlü ses almak.

**Architecture:** TLS'i yeni bir `web` (nginx) container'ı terminate eder; statik istemciyi sunar ve `/ws` yolunu `voip_net` içindeki Kamailio'nun düz WS soketine proxy'ler. Kamailio kayıt ve yetkilendirmenin tek sahibi kalır, WS istemcilerini `set_contact_alias()`/`handle_ruri_alias()` çifti ile adresler. Medya nginx'e ve Kamailio'ya hiç uğramaz: tarayıcı ile FreeSWITCH arasında DTLS-SRTP olarak akar, FreeSWITCH OPUS→PCMU transcode edip Zoiper'a düz RTP verir.

**Tech Stack:** Kamailio 6.0 (`websocket.so`, `xhttp.so`), nginx 1.27-alpine, OpenSSL 3 (self-signed), JsSIP (vendor'lanmış), FreeSWITCH `mod_sofia` + `mod_opus`, PostgreSQL 16, Docker Compose.

**Spec:** [docs/superpowers/specs/2026-08-13-webrtc-wss-kamailio-design.md](../specs/2026-08-13-webrtc-wss-kamailio-design.md)

## Global Constraints

- **Mevcut UDP yolu davranış olarak değişmeyecek.** WebRTC ayrı bir routing dalı olarak eklenir. Her task'ın son doğrulaması `./scripts/verify-all.sh` → `FAIL=0` içerir.
- **Faz 1 yalnız tarayıcı→Zoiper yönü.** Zoiper→tarayıcı yönü kapsam dışı (spec bölüm 6); bu yönü çalıştırmaya yönelik hiçbir kod yazılmaz.
- **Otomatik test bu fazda yazılmaz.** Doğrulama, her task'ta verilen kabuk komutları ve tarayıcıdaki elle kontroldür. `tools/ws-sip-probe.py` + `scripts/verify-13-webrtc.sh` sonraki iş (spec bölüm 10).
- **Etkisi ölçülmemiş parametre config'de bırakılmaz.** Bir parametre denendi ve işe yaramadıysa silinir; config'de durması "yapılandırdım" yanılgısı yaratır (`ext-sip-port` bu repoda tam böyle oldu).
- **Sırlar `.env`'de.** Hiçbir şifre, port veya IP koda gömülmez. Yeni değer: `WEB_TLS_PORT=8443`.
- **Kamailio'ya publish edilmiş yeni port eklenmez.** WS soketi `voip_net` içinde kalır.
- **Sertifika kalıcıdır.** Named volume'da yaşar; yeniden üretmek tarayıcıdaki güvenlik istisnasını geçersiz kılar.
- **Yorumlar Türkçe, commit mesajları İngilizce** — mevcut repo deseni.
- `EXTERNAL_IP=192.168.1.3` (bu makinede). Komutlarda `$EXTERNAL_IP` kullanılır, elle IP yazılmaz.

## Dosya yapısı

| Dosya | Sorumluluk |
|---|---|
| `kamailio/Dockerfile` | `kamailio-websocket-modules` paketi |
| `kamailio/kamailio.cfg` | WS listener + tcp parametreleri, `xhttp`/`websocket` yükleme, handshake `event_route`, NAT'ta WS dalı, dönüş yolunda `handle_ruri_alias()` |
| `web/Dockerfile` | nginx:1.27-alpine + openssl imajı |
| `web/entrypoint.sh` | Idempotent self-signed sertifika üretimi (runtime, `EXTERNAL_IP` SAN'ı) |
| `web/nginx.conf` | 8443 TLS, statik kök, `/ws` WebSocket proxy'si |
| `web/index.html` | İstemci arayüzü — form, düğmeler, `<audio>`, log alanı |
| `web/client.js` | JsSIP bağlantısı: register, çağrı, olay logu. Arayüzden ayrı tutuldu; SDP/ICE ayıklaması bu dosyada toplanır |
| `web/vendor/jssip.min.js` | Vendor'lanan bağımlılık (CDN yok) |
| `web/vendor/VERSION` | İndirilen JsSIP sürümü + sha256 |
| `docker-compose.yml` | `web` servisi, `voip_web_certs` volume'u |
| `.env`, `.env.example` | `WEB_TLS_PORT` |
| `README.md` | WebRTC bölümü (sertifika kabul adımı dahil) |

---

### Task 1: Kamailio WS transport ve handshake

Kamailio düz WebSocket kabul etsin. Henüz routing dokunuşu yok — bu task yalnız taşıma katmanı.

**Files:**
- Modify: `kamailio/Dockerfile:19` (paket listesi)
- Modify: `kamailio/kamailio.cfg:38` (global), `:40` (listen), `:76` (modül listesi sonu), dosya sonu (`event_route`)

**Interfaces:**
- Consumes: yok (ilk task)
- Produces: `voip_net` içinde `ws://kamailio:8080/ws`, `Sec-WebSocket-Protocol: sip` ile `101 Switching Protocols` döner. Task 2'nin nginx proxy hedefi budur.

- [ ] **Step 1: Dockerfile'a websocket paketini ekle**

`kamailio/Dockerfile` içinde `kamailio-tls-modules && \` satırını şununla değiştir:

```dockerfile
        kamailio-tls-modules \
        kamailio-websocket-modules && \
```

Paket doğrulandı: 6.0.6+bpo12, `deb.kamailio.org` üzerinde arm64 mevcut.

- [ ] **Step 2: Global bölüme WS listener ve TCP parametrelerini ekle**

`kamailio.cfg`'de `use_dns_cache=0` satırından sonra, `listen=udp:...` satırından **önce** ekle:

```
# --- WebSocket tasima katmani ---
# TLS'i nginx (web servisi) terminate eder ve buraya ws:// olarak proxy'ler,
# o yuzden burada TLS YOK. Bu soket voip_net icinde kalir; docker-compose'da
# publish EDILMEZ.
listen=tcp:0.0.0.0:8080

# WebSocket handshake bir HTTP GET'tir ve Content-Length TASIMAZ. Bu ayar
# olmadan Kamailio istegi eksik sayar ve handshake hic xhttp'ye ulasmaz.
tcp_accept_no_cl=yes

# max_expires (3600, bkz. modparam("registrar", ...)) degerinden BUYUK olmali.
# Kucuk kalirsa Kamailio soketi kayit yenilenmeden once kapatir; istemci
# location tablosunda kayitli GORUNUR ama ona ulasilamaz. Belirti yaniltici:
# REGISTER 200 OK doner, cagri hic gelmez.
tcp_connection_lifetime=3605
```

`listen=tcp:...` satırına `advertise` **yazılmaz**: WS bacağında dönüş yolu alias mekanizmasıyla çözülür (Task 3/4), advertise adresi bu bacakta hiçbir işe yaramaz.

- [ ] **Step 3: Modülleri yükle**

`loadmodule "dispatcher.so"` satırından sonra ekle:

```
# WebSocket: xhttp handshake'in HTTP GET'ini event_route'a dusurur,
# websocket modulu de upgrade'i yapip SIP mesajlarini cerceveden cikarir.
loadmodule "xhttp.so"
loadmodule "websocket.so"
```

`websocket` modülüne modparam **verilmiyor**: varsayılan `keepalive_mechanism=1` (PING) ve `keepalive_timeout=180` bu kurulum için doğru — nginx `proxy_read_timeout` 3600s olacak (Task 2), yani 180 saniyelik ping soketi fazlasıyla canlı tutar. Etkisi ölçülmeyen parametre eklenmez.

- [ ] **Step 4: Handshake event_route'unu dosya sonuna ekle**

`failure_route[FS_FAILOVER]` bloğundan sonra, dosya sonuna ekle:

```
####### WebSocket handshake #######
# nginx /ws yolunu ws://kamailio:8080'e proxy'ler. Kamailio icin bu siradan
# bir HTTP GET'tir; xhttp modulu onu bu event_route'a dusurur.
event_route[xhttp:request] {
    if ($Rp == 8080 && $rm == "GET"
        && $hdr(Upgrade) =~ "[Ww]eb[Ss]ocket"
        && $hdr(Connection) =~ "[Uu]pgrade") {
        if (ws_handle_handshake()) {
            exit;
        }
    }
    # Sessiz dusen handshake tarayicida yalnizca "connection closed" olarak
    # gorunur; sebebini ancak burada gorebiliriz. ws_handle_handshake()
    # Sec-WebSocket-Protocol basliginda "sip" arar — nginx bu basligi aynen
    # iletmek ZORUNDA (bkz. web/nginx.conf).
    xlog("L_WARN", "WS handshake reddedildi: $rm port=$Rp src=$si:$sp "
                   "upgrade='$hdr(Upgrade)' proto='$hdr(Sec-WebSocket-Protocol)'\n");
    xhttp_reply("404", "Not Found", "text/plain", "Not Found");
}
```

- [ ] **Step 5: Build et ve Kamailio'nun ayağa kalktığını doğrula**

```bash
docker compose up -d --build kamailio
sleep 3
docker compose logs kamailio --tail 40
```

Beklenen: `ERROR` veya `error -1 while trying to fix configuration` **yok**, container `Up`. Konfigürasyon hatası varsa Kamailio crash-loop'a girer — `docker compose ps` ile `Restarting` durumunu kontrol et.

- [ ] **Step 6: WS handshake'i container içinden doğrula**

```bash
docker exec voip-xmlapi curl -sS -i --http1.1 --max-time 3 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Protocol: sip" \
  http://kamailio:8080/ws | head -12
```

Beklenen ilk satır: `HTTP/1.1 101 Switching Protocols`, ve yanıtta `Sec-WebSocket-Protocol: sip`.
`curl` 101'den sonra soketi açık tuttuğu için `--max-time 3` ile 28 çıkış kodu vermesi **normaldir**; bakılan şey çıkış kodu değil, 101 satırıdır.

`404` dönerse `docker compose logs kamailio --tail 20` içindeki `WS handshake reddedildi` satırı hangi koşulun tutmadığını söyler.

- [ ] **Step 7: UDP yolunda regresyon olmadığını doğrula**

```bash
./scripts/verify-all.sh
```

Beklenen: son satırda `FAIL=0`.

- [ ] **Step 8: Commit**

```bash
git add kamailio/Dockerfile kamailio/kamailio.cfg
git commit -m "feat(kamailio): accept plain WebSocket on an internal-only socket

Load xhttp and websocket, listen on tcp/8080 inside voip_net, and answer
the handshake from a dedicated event_route. TLS terminates at the nginx
edge, so this socket carries plain ws and is never published to the host.

tcp_connection_lifetime sits above registrar max_expires on purpose: a
shorter lifetime closes the socket before the registration refreshes, and
the client then looks registered while being unreachable.

A rejected handshake is logged rather than dropped silently, because the
browser only ever sees 'connection closed'."
```

---

### Task 2: nginx TLS kenarı ve istemci iskeleti

TLS 8443'te bitsin, statik sayfa sunulsun, `/ws` Kamailio'ya proxy'lensin. JsSIP henüz yok — bu task ağ yolunu bitirir.

**Files:**
- Create: `web/Dockerfile`, `web/entrypoint.sh`, `web/nginx.conf`, `web/index.html`
- Modify: `docker-compose.yml` (yeni servis + volume), `.env`, `.env.example`

**Interfaces:**
- Consumes: Task 1'in `ws://kamailio:8080/ws` soketi
- Produces: `https://${EXTERNAL_IP}:${WEB_TLS_PORT}/` statik kök, `wss://${EXTERNAL_IP}:${WEB_TLS_PORT}/ws` SIP WebSocket'i. Task 3'ün `client.js`'i `vendor/jssip.min.js` ve `client.js` dosyalarını bu kökten yükler.

- [ ] **Step 1: `web/Dockerfile` oluştur**

```dockerfile
FROM nginx:1.27-alpine

# openssl: sertifika CALISMA ANINDA uretilir, cunku SAN degeri EXTERNAL_IP'ye
# baglidir ve build-time'da bilinmez. Imaja gomulu bir sertifika farkli
# makinelerde yanlis SAN tasir ve tarayici reddeder.
RUN apk add --no-cache openssl

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY index.html client.js /usr/share/nginx/html/
COPY vendor/ /usr/share/nginx/html/vendor/

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8443/tcp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
```

- [ ] **Step 2: `web/client.js` ve `web/vendor/` için yer tutucu oluştur**

Dockerfile bu yolları kopyaladığı için build'in geçmesi adına boş dosyalar gerekir. Task 3 ikisini de gerçek içerikle doldurur.

```bash
mkdir -p web/vendor
printf '// Task 3: JsSIP baglantisi\n' > web/client.js
printf 'jssip.min.js Task 3 icinde vendor lanir\n' > web/vendor/.gitkeep
```

- [ ] **Step 3: `web/entrypoint.sh` oluştur**

```sh
#!/bin/sh
set -eu

CERT_DIR=/etc/nginx/certs
CERT="$CERT_DIR/server.crt"
KEY="$CERT_DIR/server.key"

: "${EXTERNAL_IP:?EXTERNAL_IP tanimli olmali}"
: "${SIP_DOMAIN:?SIP_DOMAIN tanimli olmali}"

mkdir -p "$CERT_DIR"

# IDEMPOTENT. Sertifika named volume'da yasar ve VAR OLANA DOKUNULMAZ:
# yeniden uretmek tarayicidaki guvenlik istisnasini gecersiz kilar ve
# kullanicinin onu elle yeniden kabul etmesini gerektirir.
if [ -s "$CERT" ] && [ -s "$KEY" ]; then
    echo "entrypoint: mevcut sertifika kullaniliyor ($CERT)"
else
    echo "entrypoint: sertifika uretiliyor (CN=${EXTERNAL_IP})"
    # SAN sart: modern tarayicilar Common Name'e BAKMAZ, yalnizca
    # subjectAltName'e bakar. IP ile baglaniyoruz, o yuzden IP: girdisi
    # olmadan sertifika hicbir sekilde kabul edilemez.
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -keyout "$KEY" -out "$CERT" \
        -subj "/CN=${EXTERNAL_IP}" \
        -addext "subjectAltName=IP:${EXTERNAL_IP},IP:127.0.0.1,DNS:localhost,DNS:${SIP_DOMAIN},DNS:tenant1.${SIP_DOMAIN}"
    chmod 600 "$KEY"
fi

exec "$@"
```

- [ ] **Step 4: `web/nginx.conf` oluştur**

```nginx
worker_processes 1;
error_log  /dev/stderr warn;

events {
    worker_connections 256;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    /dev/stdout;
    sendfile      on;

    # Connection basligi hop-by-hop'tur; istemciden geleni aynen iletmek
    # YANLIS olur. Upgrade istegi varsa "upgrade", yoksa "close" uretiyoruz.
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    server {
        listen 8443 ssl;

        ssl_certificate     /etc/nginx/certs/server.crt;
        ssl_certificate_key /etc/nginx/certs/server.key;
        ssl_protocols       TLSv1.2 TLSv1.3;

        root  /usr/share/nginx/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }

        # SIP-over-WebSocket. Kamailio TLS gormez, duz ws konusur.
        # Sec-WebSocket-Protocol basligi AYNEN iletilir (nginx bilinmeyen
        # basliklari zaten iletir); Kamailio'nun ws_handle_handshake()
        # fonksiyonu o baslikta "sip" arar.
        location /ws {
            proxy_pass http://kamailio:8080;
            proxy_http_version 1.1;
            proxy_set_header Upgrade    $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host       $host;

            # Boste kalan WebSocket'i nginx KESMESIN. Kisa kalirsa kayit
            # sessizce duser ve istemci bunu ancak sonraki cagri denemesinde
            # fark eder.
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering    off;
        }
    }
}
```

- [ ] **Step 5: `web/index.html` oluştur**

```html
<!doctype html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WebRTC test istemcisi</title>
<style>
  body   { font: 14px/1.5 system-ui, sans-serif; margin: 2rem; max-width: 46rem; }
  label  { display: block; margin-top: .5rem; }
  input  { width: 18rem; padding: .25rem; }
  button { margin: 1rem .5rem 0 0; padding: .4rem .9rem; }
  #log   { margin-top: 1rem; height: 24rem; overflow-y: auto; padding: .5rem;
           background: #111; color: #0f0; white-space: pre-wrap;
           font: 12px/1.4 ui-monospace, monospace; }
</style>
</head>
<body>
<h1>WebRTC test istemcisi</h1>

<label>Kullanıcı <input id="user" value="alice"></label>
<label>Şifre <input id="pass" type="password" value="alice123"></label>
<label>Domain <input id="domain" value="tenant1.voip.local"></label>
<label>Aranan <input id="target" value="9999"></label>

<button id="register">Register</button>
<button id="call" disabled>Ara</button>
<button id="hangup" disabled>Kapat</button>

<audio id="remote" autoplay></audio>

<!-- Log alani zorunlu: SDP'yi, ICE durumunu ve SIP cevaplarini gormenin
     tek yolu bu. DTLS/ICE tanisi bu ciktiya dayaniyor. -->
<div id="log"></div>

<script src="vendor/jssip.min.js"></script>
<script src="client.js"></script>
</body>
</html>
```

- [ ] **Step 6: `.env` ve `.env.example`'a portu ekle**

Her iki dosyada `# ============ FreeSWITCH ============` bölümünden önce ekle:

```
# ============ Web / WebRTC ============
# nginx TLS portu. Tarayici hem sayfayi hem WSS'i BU portta gorur; ayni
# origin oldugu icin self-signed sertifika istisnasi bir kez kabul edilir.
WEB_TLS_PORT=8443
```

- [ ] **Step 7: `docker-compose.yml`'e servisi ve volume'u ekle**

`freeswitch` servisinden sonra, `volumes:` bloğundan önce ekle:

```yaml
  web:
    build: ./web
    image: voip-web
    container_name: voip-web
    restart: unless-stopped
    environment:
      # entrypoint sertifikanin SAN'ini bunlardan uretir.
      EXTERNAL_IP: ${EXTERNAL_IP}
      SIP_DOMAIN: ${SIP_DOMAIN}
    volumes:
      # Sertifika KALICI olmali. Her yeniden kurulumda yeniden uretilirse
      # tarayicidaki guvenlik istisnasi gecersizlesir ve kullanici onu elle
      # yeniden kabul etmek zorunda kalir.
      - voip_web_certs:/etc/nginx/certs
    ports:
      # TLS ucu BURADA. Kamailio'nun ws soketi (tcp/8080) host'a publish
      # EDILMEZ; nginx ona voip_net uzerinden ulasir.
      - "${WEB_TLS_PORT}:8443"
    depends_on:
      # nginx `proxy_pass http://kamailio:8080` adresini KONFIGURASYON
      # YUKLENIRKEN cozer (degisken kullanilmadigi icin). Kamailio henuz
      # yoksa nginx "host not found in upstream" ile cikar; restart politikasi
      # onu yeniden baslatir ve ikinci denemede acilir. Bu, ayni sinif DNS
      # sirasi sorununun (bkz. dispatcher/extra_hosts yorumlari) kabul
      # edilebilir bicimidir: hata GURULTULU ve kendiliginden duzelir.
      - kamailio
    networks: [voip_net]
```

`volumes:` bloğunu şu hale getir:

```yaml
volumes:
  voip_pg_data:
  voip_web_certs:
```

- [ ] **Step 8: Build et ve statik kökü doğrula**

```bash
docker compose up -d --build web
sleep 3
docker compose logs web --tail 20
set -a; . ./.env; set +a
curl -k -sS -o /dev/null -w 'sayfa: %{http_code}\n' "https://${EXTERNAL_IP}:${WEB_TLS_PORT}/"
```

Beklenen: loglarda `entrypoint: sertifika uretiliyor (CN=192.168.1.3)`, ve `sayfa: 200`.

İlk açılışta loglarda `host not found in upstream "kamailio"` görürsen bu beklenen bir yarıştır: nginx upstream'i konfigürasyon yüklenirken çözer, restart politikası onu yeniden başlatır. `docker compose ps` ile `web` servisinin `Up` olduğunu doğrula; sürekli `Restarting` kalıyorsa Kamailio ayakta değil demektir.

- [ ] **Step 9: Sertifika SAN'ını doğrula**

```bash
set -a; . ./.env; set +a
openssl s_client -connect "${EXTERNAL_IP}:${WEB_TLS_PORT}" </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
```

Beklenen: `IP Address:192.168.1.3` listede. Yoksa tarayıcı sertifikayı hiçbir koşulda kabul etmez.

- [ ] **Step 10: Sertifikanın restart'ta değişmediğini doğrula**

```bash
set -a; . ./.env; set +a
fp() { openssl s_client -connect "${EXTERNAL_IP}:${WEB_TLS_PORT}" </dev/null 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256; }
BEFORE=$(fp)
docker compose restart web && sleep 3
AFTER=$(fp)
[ "$BEFORE" = "$AFTER" ] && echo "SERTIFIKA KALICI: ok" || echo "HATA: sertifika yeniden uretildi"
```

Beklenen: `SERTIFIKA KALICI: ok`. Değişiyorsa volume mount edilmemiş demektir.

- [ ] **Step 11: WSS proxy'sinin uçtan uca 101 döndürdüğünü doğrula**

```bash
set -a; . ./.env; set +a
curl -k -sS -i --http1.1 --max-time 3 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Protocol: sip" \
  "https://${EXTERNAL_IP}:${WEB_TLS_PORT}/ws" | head -12
```

Beklenen: `HTTP/1.1 101 Switching Protocols` ve `Sec-WebSocket-Protocol: sip`. `--max-time` yüzünden 28 çıkış kodu normaldir.

`502` gelirse nginx Kamailio'ya ulaşamıyor (servis adı/port); `404` gelirse istek Kamailio'ya ulaşıyor ama handshake koşulları tutmuyor — `docker compose logs kamailio --tail 20`.

- [ ] **Step 12: UDP regresyonu ve commit**

```bash
./scripts/verify-all.sh
```

Beklenen: `FAIL=0`.

```bash
git add web docker-compose.yml .env.example
git commit -m "feat(web): add nginx TLS edge serving the client and proxying SIP WebSocket

Terminate TLS at nginx on one port so the page and the WebSocket share an
origin; a self-signed certificate then needs a single browser exception
instead of one per port. Kamailio gains no published port.

The certificate is generated at runtime, not baked into the image, because
its subjectAltName depends on EXTERNAL_IP. It lives in a named volume and
an existing one is never regenerated: a new certificate would invalidate
the exception the user already accepted. Browsers ignore Common Name, so
the IP SAN entry is what makes the connection acceptable at all.

proxy_read_timeout is long on purpose. A short timeout closes an idle
WebSocket and the registration then dies silently, which the client only
notices on its next call attempt."
```

Not: `.env` `.gitignore`'da, o yüzden commit'e girmez — yalnız `.env.example`.

---

### Task 3: JsSIP istemcisi ve WSS üzerinden REGISTER

Tarayıcı `alice` olarak kayıt olsun ve `location` tablosunda alias'lı bir ws contact'ı görünsün.

**Files:**
- Create: `web/vendor/jssip.min.js`, `web/vendor/VERSION`
- Modify: `web/client.js` (yer tutucu → gerçek içerik), `kamailio/kamailio.cfg:131-139` (NAT bloğu)
- Delete: `web/vendor/.gitkeep`

**Interfaces:**
- Consumes: Task 2'nin `wss://.../ws` uç noktası
- Produces: `location` tablosunda `contact` alanı `;alias=<ip>~<port>~ws` içeren kayıt. Task 4'ün `handle_ruri_alias()` çağrısı tam bu alias'ı tüketir.

- [ ] **Step 1: JsSIP'i vendor'la**

**Bu bir dosya indirmesidir; çalıştırmadan önce kullanıcıdan onay al.** Kaynak, dosya ve yaklaşık boyut: `jssip.min.js`, jsDelivr üzerinden npm `jssip` paketi, ~230KB.

```bash
mkdir -p web/vendor
curl -fsSL -o web/vendor/jssip.min.js \
  "https://cdn.jsdelivr.net/npm/jssip@3/dist/jssip.min.js"
VER=$(curl -fsSL "https://data.jsdelivr.com/v1/packages/npm/jssip/resolved?specifier=3" \
       | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
printf 'jssip %s\nsha256 %s\nkaynak https://cdn.jsdelivr.net/npm/jssip@3/dist/jssip.min.js\n' \
  "$VER" "$(shasum -a 256 web/vendor/jssip.min.js | cut -d' ' -f1)" > web/vendor/VERSION
rm -f web/vendor/.gitkeep
cat web/vendor/VERSION
```

Sürüm ve sha256 kayda geçer; bağımlılığın hangi ikili olduğunu sonradan doğrulamanın tek yolu bu.

- [ ] **Step 2: Kamailio NAT bloğuna WS dalını ekle**

`kamailio.cfg` içindeki mevcut NAT bloğunu (`# NAT` yorumundan `nat_uac_test` bloğunun kapanışına kadar) şununla değiştir:

```
    # NAT
    # WS/WSS bacagi AYRI ele alinir. Bu istemcilerin Contact host'u sahte bir
    # .invalid domainidir (ornek: sip:xyz@df7jal23ls0d.invalid;transport=ws)
    # ve geri yol bir TCP soketidir. `received=` bir soketi tarif edemez, o
    # yuzden fix_nated_register() WS icin YETERSIZ: kayit basarili olur ama
    # istemciye giden hicbir istek yolunu bulamaz.
    # set_contact_alias() kaynak ip~port~proto ucluusunu Contact URI'sine
    # `alias` parametresi olarak gomer; donus yolunda handle_ruri_alias()
    # bunu $du'ya cevirip YERLESIK soketi yeniden kullanir.
    # `proto` bir PV DEGIL, core keyword'dur — $proto PV'si string doner ve
    # karsilastirma sessizce eslesmez.
    # Not: TLS'i nginx terminate ettigi icin buradaki kaynak adres her zaman
    # web container'inin IP'sidir; her tarayici ayri bir kaynak PORT tasir,
    # dolayisiyla alias'lar birbirine karismaz.
    if (proto == WS || proto == WSS) {
        set_contact_alias();
    } else {
        force_rport();
        if (nat_uac_test("19")) {
            if (is_method("REGISTER")) {
                fix_nated_register();
            } else {
                fix_nated_contact();
            }
        }
    }
```

- [ ] **Step 3: `web/client.js`'i yaz**

```js
'use strict';

const el = (id) => document.getElementById(id);
const logBox = el('log');

function log(msg) {
  const t = new Date().toISOString().substring(11, 23);
  logBox.textContent += `${t}  ${msg}\n`;
  logBox.scrollTop = logBox.scrollHeight;
}

let ua = null;
let session = null;

function resetCall() {
  session = null;
  el('remote').srcObject = null;
  el('call').disabled = false;
  el('hangup').disabled = true;
}

el('register').addEventListener('click', () => {
  if (ua) {
    log('UA zaten var — sayfayi yenileyip tekrar deneyin');
    return;
  }

  const user = el('user').value.trim();
  const domain = el('domain').value.trim();

  // WSS adresi sayfanin origin'inden turetilir. Sayfa ve WebSocket ayni
  // host:port uzerinde oldugu icin tarayicida TEK sertifika istisnasi yeter,
  // ve HTML'e hicbir ortam degiskeni render etmemiz gerekmez.
  const wsUrl = `wss://${location.host}/ws`;
  log(`WebSocket: ${wsUrl}`);

  ua = new JsSIP.UA({
    sockets: [new JsSIP.WebSocketInterface(wsUrl)],
    uri: `sip:${user}@${domain}`,
    authorization_user: user,
    password: el('pass').value,
    session_timers: false,
    register: true,
  });

  ua.on('connected', () => log('WebSocket bagli'));
  ua.on('disconnected', (e) => log(`WebSocket koptu (${e && e.error ? 'hata' : 'normal'})`));
  ua.on('registered', () => {
    log('REGISTER 200 OK');
    el('call').disabled = false;
  });
  ua.on('unregistered', () => {
    log('kayit dusuldu');
    el('call').disabled = true;
  });
  ua.on('registrationFailed', (e) => log(`REGISTER basarisiz: ${e.cause}`));

  ua.start();
});

el('call').addEventListener('click', () => {
  const target = `sip:${el('target').value.trim()}@${el('domain').value.trim()}`;
  log(`ARIYOR ${target}`);

  session = ua.call(target, {
    // Mikrofon izni ICE icin ON KOSULDUR: izin verilmeden Chrome yerel
    // IP'leri saklar ve host candidate yerine cozumlenemeyen bir .local mDNS
    // adi yayinlar. FreeSWITCH o adi cozemez, connectivity check hic
    // baslamaz ve belirti "cagri kuruluyor, ses yok" olur.
    mediaConstraints: { audio: true, video: false },
    // STUN gereksiz: sunucunun adresi zaten erisilebilir, baglantiyi tarayici
    // baslatir ve FreeSWITCH symmetric RTP ile kaynaga geri gonderir. STUN
    // yalnizca ICE toplama suresini uzatir.
    pcConfig: { iceServers: [] },
  });

  // SDP logu tanida zorunlu: DTLS fingerprint'i, ICE candidate'lari ve medya
  // profilinin (UDP/TLS/RTP/SAVPF) iki tarafta ne oldugunu baska yerden
  // goremiyoruz.
  session.on('sdp', (e) => log(`SDP ${e.originator} ${e.type}:\n${e.sdp}`));

  session.on('peerconnection', (e) => {
    const pc = e.peerconnection;
    pc.addEventListener('track', (ev) => {
      log(`medya track alindi: ${ev.track.kind}`);
      el('remote').srcObject = ev.streams[0];
    });
    pc.addEventListener('iceconnectionstatechange', () => {
      log(`ICE durumu: ${pc.iceConnectionState}`);
    });
  });

  session.on('progress', () => log('progress (180/183)'));
  session.on('accepted', () => log('200 OK'));
  session.on('confirmed', () => log('ACK gonderildi, cagri kuruldu'));
  session.on('failed', (e) => {
    log(`cagri basarisiz: ${e.cause}`);
    resetCall();
  });
  session.on('ended', (e) => {
    log(`cagri bitti: ${e.cause}`);
    resetCall();
  });

  el('call').disabled = true;
  el('hangup').disabled = false;
});

el('hangup').addEventListener('click', () => {
  if (session) {
    session.terminate();
  }
});
```

- [ ] **Step 4: Yeniden build et ve kayıt öncesi tabloyu temizle**

```bash
docker compose up -d --build web kamailio
sleep 3
set -a; . ./.env; set +a
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "select username, domain, contact, socket, expires from location order by username;"
```

Beklenen: `alice` satırı **yok** (henüz kayıt olmadı) veya varsa eski bir UDP kaydı.

- [ ] **Step 5: Tarayıcıda kayıt ol (elle)**

1. `https://192.168.1.3:8443/` adresini aç.
2. Sertifika uyarısını kabul et (Chrome: Advanced → Proceed).
3. `Register` düğmesine bas.

Log alanında beklenen sıra: `WebSocket: wss://192.168.1.3:8443/ws` → `WebSocket bagli` → `REGISTER 200 OK`.

`REGISTER basarisiz: Unauthorized` görürsen: `ha1 = md5(alice:tenant1.voip.local:alice123)` olarak hesaplanmıştır, yani Domain alanı **tam olarak** `tenant1.voip.local` olmalı; IP yazmak sonsuz 401 döngüsü üretir.

- [ ] **Step 6: Alias'lı contact'ı doğrula**

```bash
set -a; . ./.env; set +a
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "select username, domain, contact, socket, expires from location where username='alice';"
```

Beklenen: `contact` alanı `transport=ws` **ve** `;alias=` içeriyor (örnek biçim:
`sip:xxxx@172.30.0.N:PORT;transport=ws;alias=172.30.0.N~PORT~5`). `socket` alanı `tcp:...:8080`.

`alias=` yoksa `proto == WS` dalı tutmamış demektir — `docker compose logs kamailio` içinde REGISTER satırına bak.

- [ ] **Step 7: UDP regresyonu ve commit**

```bash
./scripts/verify-all.sh
```

Beklenen: `FAIL=0`.

```bash
git add web/vendor web/client.js kamailio/kamailio.cfg
git commit -m "feat(web): register a browser client over WSS and alias its WS contact

Vendor JsSIP instead of loading it from a CDN so the container stays
self-contained, and record the resolved version and sha256 next to it.

A WebSocket client advertises a Contact whose host is a fabricated
.invalid domain and whose return path is a TCP socket, which received=
cannot describe. set_contact_alias embeds the source triple so the reply
path resolves to the established socket; the UDP branch is left untouched.

The client asks for the microphone before placing a call because that
permission is what makes Chrome publish real host candidates instead of
unresolvable mDNS names."
```

---

### Task 4: WS↔UDP yönlendirme ve echo çağrısı (DTLS/ICE ölçümü)

Tarayıcıdan `9999` aranınca kendi sesinin duyulması. Bu task planın **ölçüm** noktası: FreeSWITCH'in düz UDP SIP ile gelen WebRTC teklifini cevaplayıp cevaplamadığı burada belli olur.

**Files:**
- Modify: `kamailio/kamailio.cfg` (`loose_route()` dalı, `route[INVITE]` FS dalı)
- Koşullu olarak modify: `freeswitch/conf/sip_profiles/internal.xml.tmpl`, `freeswitch/conf/dialplan/default.xml.tmpl`, `kamailio/kamailio.cfg:187` (`record_route()` yerleşimi)

**Interfaces:**
- Consumes: Task 3'ün alias'lı `location` kaydı
- Produces: WS istemcisine giden dialog içi isteklerin (FreeSWITCH'in BYE'i dahil) yerleşik WS soketine ulaşması. Task 5 bunun üzerine Zoiper bacağını ekler.

- [ ] **Step 1: `loose_route()` dalına alias çözümünü ekle**

`kamailio.cfg`'de `has_totag()` bloğu içindeki `if (uri == myself) { $du = "sip:FS_HOST:5060"; }` ifadesini şununla değiştir:

```
            if (uri == myself) {
                $du = "sip:FS_HOST:5060";
            } else {
                # WS istemcisine giden dialog ici istek — ornegin karsi taraf
                # kapattiginda FreeSWITCH'in gonderdigi BYE. RURI'deki alias
                # parametresi yerlesik WS soketini gosterir.
                # Alias YOKSA fonksiyon RURI'ye DOKUNMAZ, yani UDP yolundaki
                # dialog ici istekler etkilenmez.
                handle_ruri_alias();
            }
```

- [ ] **Step 2: `route[INVITE]` FS dalına alias çözümünü ekle**

`route[INVITE]` içindeki `src_ip == FS_HOST` bloğunda, `lookup("location")` kontrolünden sonra ve `t_relay()`'den önce ekle:

```
        # Hedef bir WS istemcisiyse lookup RURI'ye alias parametresini geri
        # koyar; burada onu $du'ya ceviriyoruz. UDP hedeflerde alias yoktur ve
        # fonksiyon RURI'ye dokunmaz.
        handle_ruri_alias();
```

- [ ] **Step 3: Kamailio'yu yeniden yükle ve UDP regresyonunu doğrula**

```bash
docker compose up -d --build kamailio
sleep 3
./scripts/verify-all.sh
```

Beklenen: `FAIL=0`. Bu adım kritik: `handle_ruri_alias()` UDP çağrılarını bozmamalı.

- [ ] **Step 4: FreeSWITCH loglarını temizle ve tarayıcıdan 9999'u ara (elle)**

```bash
docker compose logs freeswitch --tail 0 -f > /tmp/fs-webrtc.log 2>&1 &
echo $! > /tmp/fs-log.pid
```

Tarayıcıda: sayfayı yenile → `Register` → Aranan `9999` → `Ara`. Mikrofon izni istendiğinde **izin ver**.

Log alanında beklenen sıra:
`ARIYOR sip:9999@tenant1.voip.local` → `SDP local offer:` (içinde `UDP/TLS/RTP/SAVPF`, `a=fingerprint`, `a=ice-ufrag`) → `200 OK` → `SDP remote answer:` → `ICE durumu: checking` → `ICE durumu: connected` → `medya track alindi: audio` → **kendi sesini duyuyorsun**.

```bash
kill "$(cat /tmp/fs-log.pid)"
grep -iE "dtls|fingerprint|ice|candidate|SAVPF|CRYPTO" /tmp/fs-webrtc.log | head -40
```

- [ ] **Step 5: Sonucu değerlendir**

**Ses duyuluyorsa:** Step 6'yı atla, Step 7'ye geç.

**`SDP remote answer` içinde `a=fingerprint` YOKSA veya ICE `checking`'de takılıyorsa:** Step 6'daki merdiveni sırayla uygula. Merdivenin her kademesinde tek değişken değiştirilir ve Step 4 tekrar edilir. **İşe yaramayan değişiklik geri alınır** — etkisi ölçülmemiş parametre config'de bırakılmaz.

- [ ] **Step 6: Risk merdiveni (yalnız Step 5 gerektirdiyse)**

**Kademe 1 — candidate ACL.** En olası sebep: profilde `apply-candidate-acl` tanımlı değil, FreeSWITCH'in varsayılanı tarayıcının `192.168.1.x` host candidate'ını eliyor. `freeswitch/conf/sip_profiles/internal.xml.tmpl` içinde `local-network-acl` parametresinden sonra ekle:

```xml
    <!-- Tarayicinin ICE candidate'i private LAN adresidir (192.168.1.x).
         Varsayilan candidate ACL'i onu eliyorsa FreeSWITCH connectivity
         check'i nereye gonderecegini bilemez; belirti "200 OK geliyor, ICE
         connected olmuyor, ses yok" olur.
         Regresyon: tarayicidan 9999 cagrisinda ICE durumu connected olmali. -->
    <param name="apply-candidate-acl" value="localnet.auto"/>
    <param name="apply-candidate-acl" value="wan_v4.auto"/>
```

```bash
docker compose up -d --build freeswitch && sleep 8
```

Step 4'ü tekrar et.

**Kademe 2 — kanal değişkenleri.** Kademe 1 yetmediyse `freeswitch/conf/dialplan/default.xml.tmpl` içindeki `echo-test` extension'ında `answer`'dan **önce** ekle:

```xml
        <action application="set" data="rtcp_mux=true"/>
        <action application="set" data="rtp_secure_media=mandatory"/>
```

```bash
docker compose up -d --build freeswitch && sleep 8
```

Step 4'ü tekrar et. `fs_cli` ile canlı değeri kontrol et — config'de doğru görünüp canlıda farklı olmak bu repoda yaşanmış bir sınıf hata:

```bash
set -a; . ./.env; set +a
docker compose exec -T freeswitch fs_cli -p "$FS_ESL_PASSWORD" -x \
  "xml_locate dialplan context default" | grep -A3 "echo-test"
```

İki değişkenden hangisinin gerçekten etkili olduğunu **tek tek** ölç; etkisiz olanı sil.

**Kademe 3 — rtpengine.** Kademe 1 ve 2 de yetmediyse burada dur, bulguları not et ve kullanıcıya bildir. rtpengine'i Kamailio'ya köprü olarak eklemek bu planın kapsamı dışında ayrı bir iştir (spec bölüm 7); medyayı ikinci kez relay eder ve RTP aralığını ikinci kez publish etmeyi gerektirir.

- [ ] **Step 7: Tarayıcıdan kapatmanın temiz çalıştığını doğrula**

Çağrı sürerken `Kapat` düğmesine bas. Log alanında `cagri bitti:` görünmeli.

```bash
set -a; . ./.env; set +a
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "select destination_number, duration, hangup_cause from cdr order by start_stamp desc limit 3;"
```

Beklenen: `9999|<gerçek süre>|NORMAL_CLEARING`.

`duration=32` ve `NORMAL_UNSPECIFIED` görürsen bu spec bölüm 4.5'teki `record_route()` yerleşimi sorunudur: WS↔UDP geçişinde çift Record-Route üretilmemiş. Çözüm — `kamailio.cfg`'de `request_route` içindeki şu bloğu **kaldır**:

```
    if (!is_method("REGISTER")) {
        record_route();
    }
```

ve `route[INVITE]` içinde `ds_select_dst()` başarılı olduktan sonra, `t_relay()` çağrısından önce şunu ekle:

```
    # Record-Route BURADA yazilir, hedef secildikten SONRA: cikis soketi
    # belli olmadan Kamailio WS<->UDP gecisi icin gereken CIFT Record-Route'u
    # uretemez. Yerlesimi yukari almak, tarayici bacagi ile UDP bacaginin
    # dialog ici isteklerinin birbirinin transportuna yonlenmesine yol acar;
    # belirtisi cagrinin kapanmamasi ve CDR'da duration=32 birikmesidir.
    record_route();
```

Ardından `docker compose up -d --build kamailio`, `./scripts/verify-all.sh` (FAIL=0) ve Step 4 + Step 7'yi tekrar et.

- [ ] **Step 8: Commit**

Yalnız gerçekten değişen dosyaları ekle (merdivende geri alınanları değil):

```bash
git add kamailio/kamailio.cfg
git commit -m "feat(kamailio): route in-dialog requests back to WebSocket clients

lookup and loose_route hand back a request URI carrying the alias written
at registration time; handle_ruri_alias turns it into a destination so the
established WebSocket socket is reused. Without it FreeSWITCH's BYE toward
a browser leg has nowhere to go and the call never tears down.

The call is placed only after the alias is resolved for both paths, so a
UDP peer, whose request URI carries no alias, is left untouched."
```

Merdivende kalıcı bir FreeSWITCH değişikliği yaptıysan onu **ayrı** commit'le:

```bash
git add freeswitch/conf/sip_profiles/internal.xml.tmpl
git commit -m "fix(freeswitch): accept the browser's private ICE candidate

The default candidate ACL discards the browser's LAN host candidate, so
FreeSWITCH has no validated pair to send media to. The symptom is a call
that reaches 200 OK and stays silent with ICE stuck in checking."
```

---

### Task 5: Zoiper ile çift yönlü çağrı

Tarayıcıdan `bob`u (Zoiper, UDP) arayıp iki yönlü ses almak ve her iki taraftan kapatmanın temiz çalıştığını doğrulamak.

**Files:** kod değişikliği beklenmiyor. Bu task Task 1-4'ün birleşimini gerçek uçlarla doğrular; çıkan kusur ilgili dosyada düzeltilir.

**Interfaces:**
- Consumes: Task 4'ün çalışan echo yolu
- Produces: Faz 1'in kabul ölçütü karşılanmış olur

- [ ] **Step 1: Zoiper'ı `bob` olarak kaydet (elle)**

Ayarlar: Domain `tenant1.voip.local`, kullanıcı `bob`, şifre `bob123`, transport **UDP**. `tenant1.voip.local` çözülmüyorsa outbound proxy'yi `192.168.1.3:5060` yap.

```bash
set -a; . ./.env; set +a
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "select username, contact, socket from location order by username;"
```

Beklenen: `alice` (ws, alias'lı) ve `bob` (udp) satırlarının **ikisi birlikte**.

- [ ] **Step 2: Tarayıcıdan bob'u ara (elle)**

Aranan alanına `bob` yaz, `Ara`. Zoiper çalmalı, cevapla.

Beklenen: **iki yönlü ses**. Tarayıcı logunda `ICE durumu: connected` ve `medya track alindi: audio`.

Tek yönlü ses varsa yön önemlidir:
- Tarayıcı Zoiper'ı duymuyor → FreeSWITCH'in tarayıcı bacağına gönderdiği SRTP yolu; ICE/candidate tarafına bak.
- Zoiper tarayıcıyı duymuyor → FreeSWITCH'in Zoiper bacağındaki SDP adresi; bu `ext-rtp-ip`/`local-network-acl` alanı ve `verify-08-echo.sh` adım 7'nin koruduğu davranıştır.

- [ ] **Step 3: Zoiper'dan kapat ve CDR'ı doğrula**

Çağrıyı **Zoiper tarafından** kapat. Bu, FreeSWITCH'in BYE'ini tarayıcıya ulaştıran yolu (Task 4 Step 1) sınayan tek senaryodur.

Tarayıcı logunda `cagri bitti:` görünmeli ve düğmeler sıfırlanmalı.

```bash
set -a; . ./.env; set +a
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "select caller_id_number, destination_number, duration, hangup_cause
     from cdr order by start_stamp desc limit 3;"
```

Beklenen: `bob` hedefli satırda `hangup_cause = NORMAL_CLEARING` ve gerçek süre.
`duration=32` + `NORMAL_UNSPECIFIED` → Task 4 Step 7'deki `record_route()` düzeltmesi gerekli.

Tarayıcı logunda `cagri bitti:` **hiç görünmüyorsa** BYE tarayıcıya ulaşmamıştır:

```bash
docker compose logs kamailio --tail 60 | grep -iE "loose_route|alias|BYE"
```

`loose_route basarisiz` satırı varsa Route başlığı sorunudur (spec bölüm 4.5).

- [ ] **Step 4: Ters yönü ve tarayıcıdan kapatmayı da dene (beklenen sonuç dahil)**

Zoiper'dan `alice`i ara. **Beklenen: başarısız.** Bu yön spec bölüm 6 gereği kapsam dışı; FreeSWITCH düz `RTP/AVP` teklifi üretir ve Chrome DTLS'siz medyayı reddeder.

Gözlenen davranışı (hangi hata kodu, tarayıcı ne diyor) not al — sonraki fazın başlangıç verisi bu.

- [ ] **Step 5: Tam doğrulama ve commit**

```bash
./scripts/verify-all.sh
```

Beklenen: `FAIL=0`.

Bu task'ta kod değişmediyse commit yok. Bir kusur düzelttiyse tek konuya odaklı ayrı commit yaz.

---

### Task 6: Dokümantasyon

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1-5'in çalışan kurulumu ve Task 4'te ölçülen gerçek davranış
- Produces: yok (son task)

- [ ] **Step 1: README'ye WebRTC bölümü ekle**

`## SIP trunk` bölümünden **önce** ekle (README İngilizce yazılmış, aynı dilde devam):

```markdown
## Browser client (WebRTC)

A browser can register over SIP-over-WSS and call an extension or a
UDP-registered softphone. nginx terminates TLS on `WEB_TLS_PORT`, serves the
client page and proxies `/ws` to Kamailio's WebSocket socket, which stays
inside the compose network and is never published. Media does not pass
through nginx or Kamailio: it flows directly between the browser and
FreeSWITCH as DTLS-SRTP, and FreeSWITCH transcodes OPUS to PCMU for the UDP
leg.

```bash
docker compose up -d --build web
open https://<EXTERNAL_IP>:8443/
```

The certificate is self-signed, so accept the browser warning once. It is
generated at first start with `EXTERNAL_IP` in its subjectAltName and kept in
a named volume, so the exception survives a rebuild. Page and WebSocket share
one origin, so one exception covers both.

| Field | Value |
|---|---|
| Username | `alice` |
| Password | `alice123` |
| Domain | `tenant1.voip.local` |

**Grant the microphone permission.** Without it Chrome hides local addresses
behind mDNS `.local` ICE candidates, FreeSWITCH cannot resolve them, and the
call connects with no audio.

**Only the browser-originated direction works.** Calling a browser client
from a UDP softphone does not: signalling reaches FreeSWITCH as plain UDP
SIP, so it offers `RTP/AVP` and the browser rejects media without DTLS. That
direction needs SDP mangling and is not implemented — see
`docs/superpowers/specs/2026-08-13-webrtc-wss-kamailio-design.md`.

The published RTP range allows roughly six concurrent calls once both legs
are counted; raise `RTP_END` before increasing concurrency.
```

- [ ] **Step 2: Softphone bölümüne çapraz gönderme ekle**

`## Softphone settings (Zoiper etc.)` bölümünün sonuna ekle:

```markdown
For a browser client instead of a softphone, see **Browser client (WebRTC)**
below; it registers over WSS on a different port and needs no `/etc/hosts`
entry.
```

- [ ] **Step 3: Task 4'te ölçülen gerçek davranışı yansıt**

Merdivenden kalıcı bir değişiklik geldiyse (`apply-candidate-acl` veya bir kanal değişkeni), README'nin WebRTC bölümüne bir satır ekle ve **neden gerektiğini** yaz. Hiçbiri gerekmediyse hiçbir şey eklenmez — yapılmayan yapılandırmayı belgelemek bu repoda özellikle kaçınılan bir hatadır.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document the browser WebRTC client and its limits

State the microphone requirement, since without it Chrome publishes mDNS
candidates FreeSWITCH cannot resolve and the call connects silently. State
that only the browser-originated direction works, and why, so the missing
direction is not mistaken for a bug. Note the concurrency ceiling implied by
the published RTP range."
```

- [ ] **Step 5: Branch'i özetle**

```bash
git log --oneline main..HEAD
./scripts/verify-all.sh
```

Beklenen: `FAIL=0` ve commit'lerin task sınırlarıyla hizalı olması. Ardından
`superpowers:finishing-a-development-branch` ile birleştirme kararı alınır.
