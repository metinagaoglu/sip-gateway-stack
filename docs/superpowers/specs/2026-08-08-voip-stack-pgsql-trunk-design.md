# VoIP Stack — PostgreSQL Merkezli Kamailio + FreeSWITCH + SIP Trunk

**Tarih:** 2026-08-08
**Durum:** Onaylandı, uygulama planı bekliyor

---

## 1. Hedef

Kamailio ve FreeSWITCH'in tamamen PostgreSQL üzerinden çalıştığı, tek bir
`docker-compose.yml` ile hem yerelde (macOS + Zoiper) hem de sunucuda (DNS ile
yönlendirilen dockerize kurulum) **birebir aynı şekilde** ayağa kalkan bir SIP
stack'i. Uçtan uca doğrulandıktan sonra bir SIP trunk bağlanıp gerçek çağrı
testi yapılacak.

**Taşınabilirlik kısıtı:** Hiçbir bileşen macOS'a özgü olmayacak. Yerel ile
sunucu arasındaki tek fark `.env` dosyasının içeriği olacak.

---

## 2. Mevcut durumun tespiti

Proje 3 ay durmuş ve şu haliyle çalışmıyor — bunu `QUICK_START.md` kendisi de
belirtiyor. Tespit edilen sorunlar:

| # | Sorun | Kanıt |
|---|---|---|
| 1 | İki compose dosyası, hangisinin geçerli olduğu belirsiz | `docker-compose.yml` eski `init.sql`'i, `docker-compose.pgsql.yml` yeni şemayı kullanıyor |
| 2 | 7 markdown doküman birbiriyle çelişiyor | `FREESWITCH_POSTGRESQL_STATUS.md` hâlâ `safarov/freeswitch` image'ından ve "mod_cdr_pgsql yok" iddiasından bahsediyor; Dockerfile ise kaynaktan derliyor ve `mod_cdr_pg_csv` mevcut |
| 3 | **Kamailio'da kimlik doğrulama tamamen kapalı** | `kamailio/kamailio.cfg` REGISTER'da doğrudan `save("location")` çağırıyor; `auth_db` yüklü ama `www_authenticate()` hiç çağrılmıyor → açık relay |
| 4 | dispatcher modülü hiç yüklenmiyor | `dispatcher.list` ve DB tablosu var, README load balancing iddia ediyor, ama cfg'de `loadmodule "dispatcher.so"` yok — hardcoded `$du = "sip:freeswitch:5060"` |
| 5 | Medya/NAT planı yok | rtpengine yok, FreeSWITCH `-nonat` ile başlatılıyor, `ext-rtp-ip`/`ext-sip-ip` ayarı yok |
| 6 | SIP trunk tanımlı değil | `freeswitch/conf/sip_profiles/external/netgsm.xml` ismi trunk ima ediyor ama içeriği `gateway name="kamailio"`, `register=false` |
| 7 | Dialplan bozuk | `freeswitch/conf/dialplan/default.xml` `<include><context>` sarmalayıcısı olmadan `<extension>` ile başlıyor |
| 8 | **`pgsql` diye bir dialplan uygulaması yok** | Aynı dosyadaki CDR INSERT'i hiçbir zaman çalışmadı; `mod_pgsql` bir veritabanı *arayüzü* modülü, dialplan uygulaması sağlamıyor |
| 9 | **Event socket hiç bind olmuyor** | Log: `mod_event_socket.c:2960 Cannot get information about IP address ::` — `listen-ip` `::` (IPv6), container'da IPv6 yok, thread ölüyor → yayınlanan 8021 portu ve `fs_cli` çalışmıyor |
| 10 | İki modül yüklenemiyor | Log: `Error Loading module mod_verto.so` ve `mod_signalwire.so` — build'de devre dışı bırakılmışlar ama vanilla `modules.conf.xml` hâlâ yüklemeye çalışıyor |
| 11 | Kamailio image'ı emülasyonda | `ghcr.io/kamailio/kamailio:6.0.3-focal` sadece amd64; host arm64 → QEMU. Container `Exited (137)` (OOM/kill) almış |
| 12 | Sırlar hardcoded | Şifreler compose ve config dosyalarına gömülü, `.env` yok |
| 13 | Bayat IP | `kamailio.cfg` regex'inde `192.168.1.4`, makinenin gerçek adresi `192.168.1.3` |

### Korunacak varlıklar

- **`init_full_pgsql.sql` şeması Kamailio 6.0 ile tam uyumlu.** Tablo sürümleri
  doğru: `subscriber` v7, `location` v9, `acc` v5, `missed_calls` v4,
  `dispatcher` v4. Sıfırdan yazmaya gerek yok.
- **`xmlapi/` Flask servisi** — FreeSWITCH directory ve dialplan'ını PG'den
  besleyen doğru tasarlanmış bir bileşen. Tenant-aware hale getirilecek.
- **FreeSWITCH kaynak derlemesi çalışıyor.** Doğrulandı (bkz. §9).

---

## 3. Kapsam

### MVP'de var

- PostgreSQL: tek container, iki veritabanı (`kamailio`, `freeswitch`)
- Kamailio: registrar + digest auth + dispatcher, native arm64
- FreeSWITCH: B2BUA + medya anchor, PostgreSQL'e **dört katmanda** bağlı
- Çok kiracılılık (multi-tenant, `use_domain=1`)
- Kamailio dispatcher ile FreeSWITCH'e yönlendirme
- FreeSWITCH CDR → PostgreSQL
- SIP trunk (giden + gelen), `.env` ile sağlayıcıdan bağımsız
- Tek `.env`, tek `docker-compose.yml`, tek `README.md`

### MVP'de yok (bilinçli)

| Dışarıda | Gerekçe |
|---|---|
| TLS / SRTP | Sertifika üretimi ve trunk tarafında ek ayar; yerel doğrulamayı yavaşlatır |
| Kamailio `acc` / `missed_calls` yazımı | FreeSWITCH CDR'ı yetkili kayıt; şema duruyor, tek modparam bloğuyla açılır |
| Voicemail, IVR, konferans | Çağrı kurulumunu doğrulamak için gereksiz |
| İkinci FreeSWITCH node'u | dispatcher tek node ile kurulur; ikincisi `dispatcher` tablosuna tek satır |
| FreeSWITCH base image'ının bookworm'a taşınması | Ayrı faz — bkz. §10 |

---

## 4. Mimari

```
softphone (Zoiper — yerelde LAN, sunucuda DNS üzerinden)
      │  SIP 5060/UDP
      ▼
┌──────────────┐   digest auth (subscriber)    ┌──────────────┐
│   Kamailio   │◄─────────────────────────────►│  PostgreSQL  │
│  registrar   │   location kaydı               │              │
│    proxy     │   dispatcher listesi           │  kamailio DB │
└──────┬───────┘                                │  freeswitch  │
       │ dispatcher (setid 1)                   │      DB      │
       ▼                                        └──▲────────▲──┘
┌──────────────┐   xml_curl (HTTP)  ┌─────────┐    │        │
│  FreeSWITCH  │───────────────────►│ xmlapi  │────┘        │
│    B2BUA     │  directory+dialplan│ (Flask) │             │
│ medya anchor │                    └─────────┘             │
│              │───────── core-db-dsn + CDR ────────────────┘
└──────┬───────┘
       │ gateway (.env ile soyut)
       ▼
   SIP sağlayıcı
```

**Medya kararı:** FreeSWITCH her çağrıda B2BUA olarak medyayı tutar; Kamailio
medya yoluna hiç girmez. Bu nedenle **rtpengine kullanılmıyor** — bir hareketli
parça az.

---

## 5. Bileşenler ve dosya yapısı

```
.env.example / .env          # tek gerçek kaynağı: IP, domain, şifreler, trunk
docker-compose.yml           # TEK compose
docker-compose.host.yml      # opsiyonel Linux sunucu override'ı (host network)
db/init/01-schema-kamailio.sql   # init_full_pgsql.sql buradan devam
db/init/02-seed.sql              # tenant + alice/bob + dispatcher + dialplan
db/init/03-freeswitch-db.sql     # CREATE DATABASE freeswitch + rol
kamailio/Dockerfile          # bookworm + deb.kamailio.org → native arm64
kamailio/kamailio.cfg        # sıfırdan yazılır
freeswitch/Dockerfile        # sürümleri sabitlenmiş kaynak derlemesi
freeswitch/entrypoint.sh     # .env değerlerini config'e enjekte eder
freeswitch/conf/             # vanilla üzerine minimal override
xmlapi/                      # korunur, tenant-aware hale getirilir
scripts/add-user.sh          # ha1/ha1b hesaplayarak subscriber ekler
scripts/test-phase*.sh       # faz doğrulama scriptleri
README.md                    # TEK doküman
docs/archive/                # eski 7 markdown buraya taşınır (silinmez)
legacy/                      # docker-compose.pgsql.yml, init.sql buraya
```

### 5.1 Kamailio yönlendirme mantığı

`kamailio.cfg` sıfırdan yazılır. Akış:

```
request_route
 ├─ mf_process_maxfwd_header + sanity_check
 ├─ NAT: force_rport, fix_nated_contact
 ├─ dialog içi istek (has_totag) → loose_route → t_relay → exit
 ├─ REGISTER
 │     ├─ www_authenticate("$fd", "subscriber")   ← ARTIK GERÇEKTEN ÇAĞRILIYOR
 │     │     başarısız → www_challenge / 401
 │     └─ save("location")
 └─ INVITE
       ├─ proxy_authenticate("$fd", "subscriber")
       ├─ ds_select_dst(1, 4)        # setid 1, round-robin
       └─ t_relay()
failure_route → ds_next_dst()        # FreeSWITCH node failover
```

- `use_domain=1` (çok kiracılılık); realm, tenant'ın domain'i
- Dahili çağrılar da FreeSWITCH'e gider — bridge'i FreeSWITCH kurar, böylece
  medya tek noktada anchor'lanır ve CDR tek yerden yazılır
- `acc` modülü MVP'de yüklenmiyor (§3)

### 5.2 FreeSWITCH profil ve güven modeli

- **`internal` profili:** `auth-calls=false`. Kimlik doğrulamayı Kamailio yaptı;
  FreeSWITCH tekrar doğrulamıyor. Güven, **ACL ile** sağlanıyor: yalnızca
  `voip_net` alt ağından ve Kamailio'dan gelen çağrılar kabul ediliyor.
  Bu profilin dışarıya açık olmaması kritik — ACL tek savunma hattı.
- **`external` profili:** trunk gateway'i `.env`'den `entrypoint.sh` ile
  üretiliyor; `TRUNK_REGISTER` değerine göre register'lı ya da IP tabanlı.
- **`modules.conf.xml`:** `mod_verto` ve `mod_signalwire` çıkarılıyor (§2/10),
  `mod_pgsql`, `mod_xml_curl`, `mod_cdr_pg_csv`, `mod_lua`, `mod_sofia`,
  `mod_dialplan_xml`, `mod_dptools`, `mod_commands` ve gerekli codec'ler kalıyor.
- **`event_socket.conf.xml`:** `listen-ip` `::` → **`0.0.0.0`** (§2/9).
- **Dialplan:** düzgün `<include><context name="default">` sarmalayıcısı;
  9999 echo, kullanıcıdan kullanıcıya, trunk çıkışı.

---

## 6. Veritabanı yerleşimi

Tek PostgreSQL container'ı, iki veritabanı:

```
kamailio     → tenants, subscriber, location, dialplan,
               dispatcher, cdr, acc, missed_calls, version
freeswitch   → FreeSWITCH iç durum tabloları (channels, calls,
               sofia_reg_internal, sofia_reg_external, tasks,
               limit_data, db_data ...)
```

FreeSWITCH'in ~15 iç tablosu Kamailio şemasını kirletmesin diye ayrı veritabanı
kullanılıyor. Aynı container, aynı bağlantı bilgileri, ayrı `dbname`.

---

## 7. FreeSWITCH → PostgreSQL: dört katman

| Katman | Mekanizma | Doğrulaması |
|---|---|---|
| **Core DB** | `switch.conf.xml` → `core-db-dsn` = `pgsql://host=postgres dbname=freeswitch ...` (build'de `--enable-core-pgsql-support` zaten var) | `psql -d freeswitch -c "SELECT * FROM sofia_reg_internal"` |
| **Directory + dialplan** | `mod_xml_curl` → `xmlapi` (Flask) → `kamailio` DB, tenant-aware | `fs_cli -x "xml_locate directory alice@tenant1.voip.local"` |
| **CDR** | `mod_cdr_pg_csv` → `kamailio.cdr` tablosu | Çağrı sonrası `SELECT * FROM cdr` |
| **Doğrudan sorgu** | `mod_lua` + `freeswitch.Dbh("pgsql://...")` — `mod_pgsql`'in veritabanı arayüzü üzerinden | Kullanıcı başına eşzamanlı çağrı limiti (`subscriber.max_calls`) kontrolü |

**Not:** Eski dialplan'daki `<action application="pgsql" .../>` çağrısı geçersiz
— `mod_pgsql` dialplan uygulaması sağlamaz. Doğrudan SQL'in desteklenen yolu
`mod_lua`'nın `Dbh` nesnesidir; `mod_lua.so` derlenmiş durumda (bkz. §9).
Doğrudan sorgu kullanımı **tek, dar bir senaryoyla sınırlı tutulacak** —
dialplan'a SQL yaymak bakımı zorlaştırır ve `xml_curl` çoğu ihtiyacı zaten
karşılar.

---

## 8. Yapılandırma, ağ ve medya

### Ortam değişkenleri (`.env`)

```
SIP_DOMAIN=voip.local          # sunucuda: voip.sirket.com
EXTERNAL_IP=192.168.1.3        # sunucuda: public IP
RTP_START=16384
RTP_END=16403
POSTGRES_PASSWORD=...
FS_ESL_PASSWORD=...
TRUNK_HOST= / TRUNK_USER= / TRUNK_PASS= / TRUNK_REGISTER=
```

Aynı image'lar, aynı compose, aynı config'ler — **yerel ile sunucu arasındaki
tek fark bu dosya.**

### Ağ modeli

Her ortamda **bridge + yayınlanmış port aralığı**. `network_mode: host`
varsayılan olarak kullanılmıyor: Linux sunucuda RTP için daha verimli olsa da
Docker Desktop'ta çalışmaz, yani "yerelde farklı, sunucuda farklı" bir kurulum
doğururdu. Sunucuya özel `docker-compose.host.yml` override'ı opsiyonel olarak
bırakılacak.

RTP aralığı dar tutuluyor: **16384–16403** (20 port ≈ 10 eşzamanlı çağrı).
Docker'da geniş UDP aralığı yayınlamak stack başlatmayı ciddi şekilde yavaşlatır.

### Medya adresleme

- Kamailio: `listen=udp:0.0.0.0:5060 advertise ${EXTERNAL_IP}:5060`
- FreeSWITCH: `ext-sip-ip` ve `ext-rtp-ip` = `${EXTERNAL_IP}`
- FreeSWITCH `-nonat` bayrağı kaldırılıyor

### Bilinen ortam farkı

Docker Desktop yayınlanan portlarda kaynak IP'yi maskeler — Kamailio istemcinin
gerçek IP'sini değil Docker gateway'ini görür. Linux'ta DNAT gerçek IP'yi korur.
Bu testi engellemiyor ama **NAT davranışı yerelde ve sunucuda birebir aynı
görünmeyecek.** Gizlenmiyor, README'ye not düşülecek.

---

## 9. Doğrulanmış teknik gerçekler

Aşağıdakiler tahmin değil; bu spec yazılmadan önce çalıştırılarak doğrulandı.

| Gerçek | Kanıt |
|---|---|
| Mevcut FreeSWITCH image'ı **native aarch64** | container içinde `uname -m` → `aarch64` |
| FreeSWITCH sürümü **zaten 1.10.12-release** | `FreeSWITCH Version 1.10.12-release+git~20240802T210227Z~a88d069d6f~64bit` |
| FreeSWITCH sorunsuz başlıyor, `SQL [Enabled]` | başlangıç logu |
| 49 modül derlenmiş; `mod_pgsql`, `mod_cdr_pg_csv`, `mod_xml_curl`, `mod_lua`, `mod_dptools` mevcut | `find /opt/freeswitch -name "mod_*.so"` |
| Config yolu `/opt/freeswitch/etc/freeswitch/` — compose mount'ları doğru | dizin listesi |
| Event socket bind olmuyor (IPv6 `::`) | `mod_event_socket.c:2960 Cannot get information about IP address ::` |
| `mod_verto` ve `mod_signalwire` yüklenemiyor | `Error Loading module ... mod_verto.so` / `mod_signalwire.so` |
| Container `SCHED_FIFO` ve nice ayarlayamıyor | `Failed to set SCHED_FIFO scheduler (Operation not permitted)` |
| Kamailio resmi image'ı sadece amd64 | `docker manifest inspect ghcr.io/kamailio/kamailio:6.0.3-focal` → yalnız `amd64` |
| `deb.kamailio.org` bookworm/arm64 paketleri sunuyor, sürüm **6.0.6** | `Packages.gz` içeriği: `kamailio-postgres-modules 6.0.6+bpo12` |
| Şema tablo sürümleri Kamailio 6.0 ile uyumlu | `subscriber` v7, `location` v9, `acc` v5, `missed_calls` v4, `dispatcher` v4 |
| Host LAN adresi `192.168.1.3` | `ipconfig getifaddr en0` |

---

## 10. Riskler ve azaltımlar

| Risk | Azaltım |
|---|---|
| FreeSWITCH kaynak derlemesi uzun (~30–60 dk) | Sürümler sabitlenir (`v1.10.12`, sofia `v1.13.18`, spandsp commit, libks tag), Docker katman cache'i korunur |
| Debian bullseye EOL'e yakın | **Ayrı faz.** Önce çalışan sistem kurulur, o sistem regresyon testi olarak kullanılıp bookworm'a geçilir. Base image geçişini stack'i çalıştırma işine düğümlemek iki riski birbirine bağlar. Bookworm'da `libssl1.1→libssl3`, `libtiff5→libtiff6`, `libavcodec58→59`, `lua5.2` paketinin kalkması gibi bilinen kırılmalar var |
| Bookworm geçişi kırılırsa | Yedek plan: SignalWire resmi apt paketleri (personal access token gerektirir) |
| `SCHED_FIFO` hatası | Compose'da `cap_add: SYS_NICE`; alınmazsa yalnızca zamanlama önceliği düşer, çalışmayı engellemez |
| mod_cdr_pg_csv şema uyumsuzluğu | `<schema>` bloğu mevcut `cdr` tablosunun kolonlarına birebir uyacak şekilde yazılır; `tenant_id` dialplan'da set edilen kanal değişkeninden map edilir |
| Docker Desktop kaynak IP maskelemesi | Belgelenir; yerel testi engellemiyor |

---

## 11. Faz planı ve geçme kriterleri

Her faz ayrı bir kapı ve ayrı bir commit. Bir faz geçmeden sonrakine geçilmez.

| Faz | İş | Geçme kriteri |
|---|---|---|
| 0 | Temizlik + iskelet: eski dokümanlar `docs/archive/`'e, ikinci compose `legacy/`'ye, `.env.example` | `docker compose config` hatasız çıktı veriyor |
| 1 | PostgreSQL + iki veritabanı + şema + seed | 9 tablo mevcut; 1 tenant, 2 kullanıcı, 1 dispatcher satırı; `freeswitch` veritabanı oluşmuş |
| 2 | Kamailio image + config | `kamailio -c` temiz; `docker inspect` mimariyi **arm64** gösteriyor; `kamcmd core.version` yanıt veriyor |
| 3 | **REGISTER** | Zoiper ile alice kayıt oluyor → `location` tablosunda satır; **yanlış şifre 401 alıyor** |
| 4 | FreeSWITCH ayağa kalkıyor | `fs_cli -x status` **çalışıyor** (event socket IPv4 düzeltmesi sonrası); `mod_verto`/`mod_signalwire` yükleme hatası yok |
| 5 | FreeSWITCH → PG dört katman | `sofia_reg_internal` PG'de sorgulanabiliyor; `/fs/directory` ve `/fs/dialplan` XML dönüyor; `xml_locate` çalışıyor |
| 6 | **Echo testi (9999)** | alice 9999'u arıyor, **çift yönlü ses** — medya tasarımının kanıtı |
| 7 | alice → bob | dispatcher üzerinden yönleniyor, çift yönlü ses, `cdr` tablosunda kayıt |
| 8 | Trunk giden | `.env`'e sağlayıcı bilgisi girilir, dış numara aranır, ses doğrulanır |
| 9 | Trunk gelen | DID → dialplan → alice çalıyor |
| 10 | Bookworm geçişi | Faz 1–9 doğrulamaları bookworm tabanlı image ile tekrar geçiyor |

**Araçlar:** `voip_net` üzerinde bir `sngrep` container'ı (SIP trace), `fs_cli`,
`kamcmd`, `psql`.

---

## 12. Geri dönüş güvenliği

- Her faz ayrı commit → bozulursa `git revert`
- Hiçbir dosya silinmiyor; eski markdown'lar `docs/archive/`'e, eski compose ve
  `init.sql` `legacy/`'ye taşınıyor
- PostgreSQL volume adı `voip_pg_data` olarak değişiyor → mevcut `pg_data`
  volume'üne ve içindeki veriye dokunulmuyor
- FreeSWITCH image'ı yeniden etiketleniyor; mevcut `voip_stack-freeswitch`
  image'ı çalışan bir yedek olarak duruyor
