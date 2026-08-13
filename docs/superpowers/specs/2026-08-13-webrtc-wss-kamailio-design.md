# Tarayıcı WebRTC İstemcisi — WSS Kenarda, Kamailio'da WS

**Tarih:** 2026-08-13
**Durum:** Onaylandı, uygulama planı bekliyor
**Branch:** `feature/webrtc-wss`

---

## 1. Hedef

Tarayıcıdan WebRTC ile arayıp UDP üzerinde kayıtlı bir Zoiper'ı konuşturmak.
Faz 1'in kabul ölçütü iki adımdır:

1. `alice` tarayıcıda kayıt olur, `9999` echo'yu arar ve kendi sesini duyar.
2. Aynı oturumdan `bob` (Zoiper, UDP) aranır ve iki yönlü ses akar.

Trunk işi bilinçli olarak ertelendi; bu tasarım tamamen internal çağrıyla
ilgilidir.

**Kısıt:** Mevcut UDP yolu (Zoiper ↔ Kamailio ↔ FreeSWITCH) davranış olarak
hiç değişmeyecek. WebRTC desteği ayrı bir routing dalı olarak eklenir,
çalışan yol yerinden oynatılmaz.

---

## 2. Mevcut durumun tespiti

WebRTC için gereken hiçbir parça yok. Ölçülen durum:

| # | Bulgu | Kanıt |
|---|---|---|
| 1 | Kamailio yalnız UDP dinliyor | `kamailio.cfg:40` — tek `listen` satırı `udp:0.0.0.0:5060` |
| 2 | `websocket.so` image'da kurulu değil | Container içinde modül dizininde yok; `kamailio-websocket-modules` paketi kurulu değil |
| 3 | `tls.so`, `xhttp.so`, `path.so`, `rtpengine.so` **mevcut** | `kamailio-tls-modules` + `kamailio-extra-modules` zaten kurulu |
| 4 | FreeSWITCH internal profilinde `wss-binding` yok | `freeswitch/conf/sip_profiles/internal.xml.tmpl` |
| 5 | FreeSWITCH DTLS sertifikaları **hazır** | Container'da `etc/freeswitch/tls/dtls-srtp.pem` ve `wss.pem` otomatik üretilmiş |
| 6 | `mod_verto` diskte var, yüklü değil | `modules.conf.xml` içinde yok. SIP-over-WSS yolunda gerekmiyor |
| 7 | Codec tarafı hazır | `CODEC_PREFS=OPUS,PCMU,PCMA`, `mod_opus` yüklü. Tarayıcı OPUS, Zoiper PCMU; FreeSWITCH B2BUA olduğu için transcode eder |
| 8 | Tarayıcıya sayfa sunan hiçbir bileşen yok | Repoda HTTPS servis eden servis veya JS SIP istemcisi yok |

`kamailio-websocket-modules` paketinin varlığı ve mimarisi doğrulandı:
6.0.6+bpo12, `deb.kamailio.org` üzerinde arm64 mevcut.

---

## 3. Mimari

Yeni tek container: `web` (nginx:alpine). TLS'i o terminate eder, Kamailio ile
`voip_net` içinde düz WS konuşur.

```
  tarayıcı ──TLS 8443──> nginx ──ws://kamailio:8080──> Kamailio ──dispatcher──> FreeSWITCH
     │       (sayfa + /ws)                                │  (REGISTER/auth)        │
     │                                                    └── lookup(location) ──> Zoiper
     │                                                                              │
     └──────────────────── DTLS-SRTP, UDP 16384-16403 ─────────────────────────────>┘
```

Sinyalizasyon nginx üzerinden geçer, **medya doğrudan tarayıcı ile FreeSWITCH
arasındadır**. nginx medya yoluna hiç girmez.

### Medya akışının mekaniği

Birbirinden bağımsız iki medya bacağı vardır, FreeSWITCH ortada köprüdür:

```
tarayıcı ══SRTP/DTLS, OPUS, 1 port══> FreeSWITCH ──RTP, PCMU, 2 port──> Zoiper
```

Sıra:

1. Tarayıcı `m=audio 9 UDP/TLS/RTP/SAVPF ...` teklif eder. Port `9` bir
   placeholder'dır; gerçek adres `a=candidate` satırlarındadır. Yanında
   `a=fingerprint`, `a=setup:actpass`, `a=ice-ufrag`/`a=ice-pwd`, `a=rtcp-mux`.
2. FreeSWITCH `c=IN IP4 ${EXTERNAL_IP}` ve RTP aralığından bir port ile cevap
   verir; kendi fingerprint'i `dtls-srtp.pem`'den gelir.
3. Tarayıcı o adrese STUN binding request atar, FreeSWITCH cevaplar ve çift
   doğrulanır. Docker RTP aralığını publish ettiği için host paketi container'a
   DNAT'lar ve kaynak IP korunur; FreeSWITCH tarayıcının gerçek LAN adresini
   görür.
4. Aynı UDP portu üzerinde DTLS el sıkışması olur. Her taraf karşının
   sertifika fingerprint'ini SDP'deki değerle karşılaştırır — MITM koruması
   buradan gelir. Ortak sırdan SRTP anahtarları türetilir (RFC 5764).
5. `rtcp-mux` sayesinde SRTP ve SRTCP tek portta akar. FreeSWITCH deşifre eder,
   OPUS→PCMU transcode eder, Zoiper'a ayrı bir port çiftinden düz RTP gönderir.

3. adım risk merdiveninin 1. maddesiyle aynı noktadır: `apply-candidate-acl`
tarayıcının candidate'ını elerse FreeSWITCH binding check'i nereye göndereceğini
bilemez.

**Port bütçesi:** `RTP_START=16384`, `RTP_END=16403` → 20 port. Tarayıcı bacağı
mux ile 1 port, Zoiper bacağı RTP+RTCP ile 2 port harcar, yani eşzamanlı ~6
çağrı. Faz 1 için yeterli; eşzamanlılık artarsa ilk büyütülecek değer
`RTP_END`'dir.

### Neden TLS kenarda, Kamailio'da değil

Tarayıcı hem sayfayı hem WebSocket'i TLS ister ve Chrome self-signed
sertifika istisnasını her `host:port` çifti için ayrı tutar. TLS'i Kamailio'da
terminate etmek sayfa için ayrı bir statik sunucu ve ayrı bir port demek, yani
kullanıcının tarayıcıda **iki kez** sertifika kabul etmesi. Kenarda terminate
edildiğinde sayfa ve WSS aynı origin'de olur: tek port, tek istisna,
sertifika tek yerde.

İkinci kazanç: Kamailio'ya yeni **publish edilmiş port eklenmez**. WS soketi
`voip_net` içinde kalır, host'a açılmaz.

Bedeli bir container daha ve "TLS Kamailio'da biter" saflığından sapmadır;
sinyalizasyon topolojisi açısından fark yoktur, Kamailio her iki durumda da
kayıt ve yetkilendirmenin tek sahibidir.

### Sertifika

`web/entrypoint.sh`, cert yoksa `EXTERNAL_IP` ve `SIP_DOMAIN` SAN'larıyla
self-signed üretir ve named volume'da tutar. Volume kalıcı olduğu için
container yeniden kurulduğunda cert değişmez ve tarayıcıdaki istisna düşmez.
Bu, `freeswitch/entrypoint.sh`'nin template render etme deseniyle aynı mantık:
runtime env'e bağlı üretim, build-time'a gömme yok.

Sayfa WSS adresini `wss://${location.host}/ws` diye türetir, yani HTML'e hiç
env render edilmez.

---

## 4. Kamailio değişiklikleri

### 4.1 Dockerfile

`kamailio-websocket-modules` paketi eklenir. `xhttp.so` zaten mevcut.

### 4.2 Global bölüm

```
listen=tcp:0.0.0.0:8080          # düz WS; yalnız voip_net içinden erişilir
tcp_accept_no_cl=yes             # WebSocket handshake'inde Content-Length yok
tcp_connection_lifetime=3605     # max_expires (3600) değerinden BÜYÜK olmalı
```

`tcp_connection_lifetime`, kayıt süresinden küçük kalırsa Kamailio soketi
kayıt yenilenmeden önce kapatır; istemci kayıtlı görünürken ona ulaşılamaz
hale gelir. 3605 bilinçli olarak `modparam("registrar", "max_expires", 3600)`
değerinin üstünde.

`listen` satırına `advertise` yazılmaz: WS bacağında Kamailio'nun kendini
duyurduğu adres nginx'in gördüğü iç adrestir ve dialog içi yönlendirme alias
mekanizmasıyla çözülür (bkz. 4.4).

### 4.3 Modüller ve handshake

```
loadmodule "xhttp.so"
loadmodule "websocket.so"
```

```
event_route[xhttp:request] {
    if ($Rp == 8080 && $rm == "GET"
        && $hdr(Upgrade) =~ "websocket" && $hdr(Connection) =~ "Upgrade") {
        if (ws_handle_handshake()) { exit; }
    }
    xlog("L_WARN", "WS handshake reddedildi: $rm $Rp src=$si\n");
    xhttp_reply("404", "Not Found", "", "");
}
```

Eşleşmeyen istek sessizce düşmez, loglanır. Sessiz düşen handshake bu sınıf
hatalarda en pahalı belirtidir: tarayıcı yalnız "connection closed" görür.

### 4.4 Routing

Üç dokunuş. UDP yolu aynen korunur, WS ayrı dala girer.

**NAT dalı** (`request_route` içindeki mevcut NAT bloğu):

```
if (proto == WS || proto == WSS) {
    set_contact_alias();
} else {
    force_rport();
    if (nat_uac_test("19")) {
        if (is_method("REGISTER")) { fix_nated_register(); }
        else { fix_nated_contact(); }
    }
}
```

WS istemcisinin Contact host'u sahte bir `.invalid` domain'idir
(`sip:xyz@df7jal23ls0d.invalid;transport=ws`) ve geri yol bir TCP soketidir.
`received=` parametresi bu yolu tarif edemez, o yüzden `fix_nated_register()`
WS için yetersizdir. `set_contact_alias()` kaynak `ip~port~proto` üçlüsünü
Contact URI'sine `alias` parametresi olarak gömer.

`proto` burada bir PV değil, core keyword'dür (`$proto` PV'si string döner);
karşılaştırma `proto == WS` biçiminde yazılır.

**`lookup("location")` sonrası** (`route[INVITE]`, `src_ip == FS_HOST` dalı) ve
**`loose_route()` dalı**nda:

```
handle_ruri_alias();
```

Alias'ı RURI'den söküp `$du`'ya çevirir, böylece Kamailio yerleşik WS
soketini yeniden kullanır. Alias yoksa fonksiyon RURI'ye dokunmaz — yani
mevcut UDP çağrıları etkilenmez.

`loose_route()` dalında sıra önemlidir: önce mevcut `uri == myself` kontrolü
(FreeSWITCH'in `ext-sip-ip` yüzünden bizi gösteren Contact'ı), sonra alias.
Alias'lı RURI'nin host'u nginx container'ının IP'sidir, `myself` değildir,
yani iki koşul çakışmaz.

### 4.5 Bilinen kırılgan nokta: record_route yerleşimi

`record_route()` şu anda hedef seçiminden **önce** çağrılıyor
(`kamailio.cfg:187`). WS bacağı ile UDP bacağı arasında geçiş yapan çağrıda
çift Record-Route gerekir ve Kamailio bunu çıkış soketini bildiği anda üretir.
O noktada RURI (`sip:bob@tenant1.voip.local`) UDP'ye çözüldüğü için doğru
çıkması muhtemel, ama garanti değil.

Bozulursa belirtisi bu repoda tanıdıktır: çağrı kurulur, ses akar, **düzgün
kapanmaz**, 32 saniye sonra zaman aşımıyla düşer ve CDR'a `duration=32` yazılır
(aynı sınıf hata `alias=SELF_IP` ve `has_totag` dalı yorumlarında anlatılıyor).

Çözüm: `record_route()`'u `route[INVITE]` içine, `ds_select_dst()` çağrısından
sonra ve `t_relay()` öncesine taşımak. Uygulama planında bu, koşullu bir adım
olarak yer alır — önce mevcut yerleşimle ölçülür.

---

## 5. Web istemci

`web/index.html` tek sayfa, `web/vendor/jssip.min.js` repoya vendor'lanır.
CDN kullanılmaz: container'ların kendi kendine yeterli olması bu repoda
yerleşik bir kural ve runtime'da internet bağımlılığı istemiyoruz.

Alanlar: kullanıcı, şifre, domain (varsayılan `tenant1.voip.local`), aranan
numara. Düğmeler: Register, Ara, Kapat. Bir `<audio autoplay>` elementi ve
ekranda SIP olay logu — log şart, spike sırasında SDP'yi görmenin tek yolu.

```js
sockets: [new JsSIP.WebSocketInterface(`wss://${location.host}/ws`)]
uri: `sip:${user}@${domain}`
authorization_user: user
password: pass
session_timers: false
pcConfig: { iceServers: [] }
```

`iceServers: []` bilinçli. STUN'un işi istemcinin NAT arkasındaki public
eşlemesini keşfetmektir; burada gerek yok çünkü sunucu tarafının adresi zaten
erişilebilir (`EXTERNAL_IP` + publish edilmiş RTP aralığı), bağlantıyı tarayıcı
başlatır ve FreeSWITCH symmetric RTP ile paketin geldiği kaynağa geri gönderir.
STUN eklemek yalnızca ICE toplama süresini uzatır. Production'da
`iceServers` eklemenin gerçek gerekçesi TURN'dür: istemcinin ağı UDP'yi
tamamen kapatmışsa medyayı TCP/443'e sokmak gerekir, STUN o durumda da
kurtarmaz.

**Mikrofon izni ICE için ön koşuldur.** Chrome, mikrofon izni verilmemişken
yerel IP'leri saklar ve host candidate yerine `xxxxxxxx.local` biçiminde mDNS
adı yayınlar. FreeSWITCH bu adı çözemez, ICE connectivity check hiç başlamaz.
Uygulamanın `getUserMedia` çağırması bu yüzden sadece ses için değil, gerçek
`192.168.1.x` host candidate'ının açılması için de gereklidir. Sıra önemli:
izin alınmadan çağrı kurulmaya çalışılırsa belirti "çağrı kuruluyor, ses yok"
olur ve sebebi SDP'de `.local` candidate'larından okunur.

`web/nginx.conf`:

- 8443 TLS, `/` statik dosyalar
- `/ws` → `http://kamailio:8080`, `proxy_http_version 1.1`, `Upgrade` ve
  `Connection: Upgrade` header'ları
- `proxy_read_timeout` / `proxy_send_timeout` 3600s

Timeout kısa kalırsa nginx boşta duran WebSocket'i keser ve kayıt sessizce
düşer; istemci bunu ancak sonraki çağrı denemesinde fark eder.

`Sec-WebSocket-Protocol: sip` header'ını JsSIP gönderir, nginx aynen iletir;
Kamailio'nun `ws_handle_handshake()`'i bu header'ı arar.

---

## 6. Kapsam sınırı — yalnız tarayıcı→Zoiper yönü

Zoiper→tarayıcı yönü **bu fazın dışındadır** ve sebebi teknik, tercih değil.

Tarayıcı→Zoiper yönünde FreeSWITCH tarayıcının DTLS teklifini **cevaplar**.
Cevaplayan taraf SDP'deki `a=fingerprint` satırını görür ve kendi
sertifikasıyla karşılık verir; bu otomatik algılama işidir.

Zoiper→tarayıcı yönünde FreeSWITCH **teklif üretmek** zorundadır ve karşı
tarafın WebRTC olduğunu bilmez: sinyalizasyon ona düz UDP SIP olarak gelir,
`wss-binding` üzerinden gelmez, dolayısıyla mod_sofia o bacağı WebRTC olarak
işaretlemez. Düz `RTP/AVP` teklifi üretir ve Chrome bunu reddeder — Chrome
DTLS'siz medya kabul etmez.

Çözümü SDP mangling'dir: ya rtpengine'de `DTLS=passive ICE=force` ile
`RTP/SAVPF`'e çevirmek, ya da FreeSWITCH tarafında hangi kanal
değişkenlerinin gerçekten etkili olduğunu ölçüp B bacağına uygulamak. İkisi de
ayrı bir iş ve ayrı bir faz.

Bu yüzden minimal istemcide gelen çağrı arayüzü de yoktur.

---

## 7. Risk merdiveni

Tek gerçek belirsizlik: FreeSWITCH, Kamailio'dan düz UDP SIP ile gelen WebRTC
teklifini (DTLS fingerprint + ICE candidate + `UDP/TLS/RTP/SAVPF`) cevaplayacak
mı. Cevaplamazsa sırayla:

1. **`apply-candidate-acl`** — `internal.xml.tmpl` profilinde bu parametre hiç
   tanımlı değil, yani FreeSWITCH'in varsayılan candidate ACL'i geçerli.
   Varsayılan, tarayıcının private LAN candidate'ını (192.168.1.x) eleyebilir.
   En olası sebep bu.
2. **Dialplan kanal değişkenleri** (`rtp_secure_media`, `rtcp_mux` ailesi) —
   hangisinin bu sürümde gerçekten etkili olduğu **ölçülecek**, tahminle
   yazılmayacak. Bu repoda `ext-sip-port` tam bu şekilde işe yaramadı ve
   config'de durduğu için "yapılandırdım" yanılgısı yarattı; o yüzden etkisi
   ölçülmeyen parametre bırakılmaz.
3. **rtpengine** — Kamailio'ya WebRTC↔SIP köprüsü olarak girer, `rtpengine.so`
   image'da hazır. Son çare, çünkü medyayı ikinci kez relay eder ve RTP port
   aralığı ikinci kez publish edilir.

---

## 8. Dosyalar

| Dosya | Değişiklik |
|---|---|
| `kamailio/Dockerfile` | `kamailio-websocket-modules` |
| `kamailio/kamailio.cfg` | WS listener, tcp parametreleri, 2 modül, `event_route[xhttp:request]`, NAT'ta WS dalı, 2× `handle_ruri_alias()` |
| `web/Dockerfile` | yeni — nginx:alpine + openssl |
| `web/entrypoint.sh` | yeni — cert üretimi (idempotent) |
| `web/nginx.conf` | yeni |
| `web/index.html` | yeni |
| `web/vendor/jssip.min.js` | yeni — vendor'lanan bağımlılık |
| `docker-compose.yml` | `web` servisi + cert volume |
| `.env`, `.env.example` | `WEB_TLS_PORT=8443` |
| `README.md` | WebRTC bölümü, sertifika kabul adımı dahil |

---

## 9. Doğrulama

Faz 1'de doğrulama **elle** yapılır: tarayıcıda sayfa açılır, sertifika kabul
edilir, kayıt olunur, `9999` ve `bob` aranır. Bu bilinçli bir karar; otomatik
test bir sonraki işe bırakıldı.

Kayıt için not: bu repoda daha önce elle doğrulamaya bırakılan iki kusur bütün
otomatik testlerden kaçmıştı (bkz. `tools/sip-uas-probe.py` docstring'i), o
yüzden otomatik test kalıcı olarak atlanmayacak, sadece sıraya alındı.

---

## 10. Sonraki işler

1. **`tools/ws-sip-probe.py` + `scripts/verify-13-webrtc.sh`** — WSS handshake,
   REGISTER 401→digest→200, `location` tablosunda alias'lı ws contact, ve
   sentetik bir WebRTC teklifiyle (`UDP/TLS/RTP/SAVPF` + `a=fingerprint` +
   `a=ice-ufrag`) `9999` çağrısı. FreeSWITCH cevabında `a=fingerprint` ve
   `a=setup:` aranır. Gerçek DTLS el sıkışması yapılmadan risk merdiveninin
   asıl sorusu böylece regresyon testine dönüşür.
2. **Zoiper→tarayıcı yönü** — bölüm 6'daki SDP mangling problemi.
3. **Trunk** — bu tasarımın dışında, mevcut `TRUNK_ENABLED` yolu üzerinden.
