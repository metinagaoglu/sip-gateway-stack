# VoIP Stack — Kamailio + FreeSWITCH + PostgreSQL

Kamailio (SIP proxy/registrar), FreeSWITCH (medya sunucusu) ve PostgreSQL'in
tek bir Docker Compose yiginda calistigi cok kiracili SIP altyapisi.
Butun yapilandirma `.env` uzerinden surulur; kod icinde ortama ozgu deger yok.

## Mimari

```
  softphone ──UDP 5060──> Kamailio ──dispatcher──> FreeSWITCH
                             │                        │
                             │  (kayit/kimlik dogr.)  │  (medya, dialplan)
                             ▼                        ▼
                        PostgreSQL: kamailio      PostgreSQL: freeswitch
                        subscriber, location,     channels, calls,
                        dispatcher, cdr           registrations, limit_data
```

**Is bolumu:** Kamailio kaydi ve digest kimlik dogrulamasini yapar, cagriyi
dispatcher ile FreeSWITCH'e verir. FreeSWITCH B2BUA olarak medyayi anchor'lar;
kayitlari bilmedigi icin kullanicidan kullaniciya cagrilari `outbound-proxy`
ile Kamailio'ya geri gonderir, Kamailio da `lookup("location")` ile hedefe
ulastirir. FreeSWITCH'te `auth-calls=false` — kimlik dogrulama tek noktada
(Kamailio) yapilir, FreeSWITCH'e erisim ACL ile kisitlanir.

**Iki veritabani kasitlidir:** `kamailio` abone/yonlendirme/raporlama verisini,
`freeswitch` ise FreeSWITCH'in operasyonel durumunu tutar.

## Hizli baslangic

```bash
cp .env.example .env
# .env icindeki EXTERNAL_IP'yi bu makinenin LAN adresi yap, sifreleri degistir
docker compose up -d --build
./scripts/verify-all.sh
```

`verify-all.sh` butun dogrulama scriptlerini kosar ve sonunda yigin durumunu
(kapsayici saglik + FreeSWITCH RestartCount) ozetler. Beklenen: `FAIL=0`.

## Softphone ayarlari (Zoiper vb.)

| Alan | Deger |
|---|---|
| Domain / SIP sunucu | `tenant1.voip.local` |
| Kullanici | `alice` (veya `bob`) |
| Sifre | `alice123` (`bob123`) |
| Transport | **UDP** |

Kamailio yalnizca UDP dinler; TCP secilirse "no transport left to try" alinir.
`tenant1.voip.local` cozulmuyorsa `/etc/hosts`'a `<EXTERNAL_IP> tenant1.voip.local`
ekleyin ya da outbound proxy olarak `<EXTERNAL_IP>:5060` verin.

**Domain'i IP yapmayin:** `subscriber.ha1` degeri
`md5(kullanici:domain:sifre)` olarak hesaplanir; realm degisirse sonsuz 401
donusu olusur.

### Test numaralari

| Numara | Davranis |
|---|---|
| `9999` | echo (soyledigini geri duyar) |
| `9998` | tone testi |
| `bob` / `alice` | kullanicidan kullaniciya cagri |
| 10-15 hane / `+E.164` / `00...` | SIP trunk (etkinse) |

## Kullanici ve kiraci ekleme

```bash
./tools/add-user.sh <kullanici> <sifre> <domain>
```

`ha1` degeri bu script tarafindan dogru realm ile hesaplanir. Elle
ekliyorsaniz: `ha1 = md5(kullanici:domain:sifre)`.

Kiracilik `use_domain=1` ile calisir: `alice@tenant1` ve `alice@tenant2`
FARKLI kullanicilardir ve birinin sifresi digerini acmaz. Bu davranis
`scripts/verify-91-tenant-isolation.sh` ile dogrulanir.

## SIP trunk

Saglayicidan bagimsiz, tek sablon iki modu karsilar. `.env`:

```
TRUNK_ENABLED=true
TRUNK_NAME=<gateway adi>
TRUNK_HOST=<saglayici host>
TRUNK_USER=<kullanici>
TRUNK_PASS=<sifre>
TRUNK_REGISTER=true     # credential modu; IP yetkilendirme icin false
```

```bash
docker compose up -d --build freeswitch
./scripts/verify-12-trunk-out.sh
```

`TRUNK_ENABLED=false` iken gateway hic olusturulmaz (entrypoint uretilen
`trunk.xml`'i siler), boylece bos adrese sonsuz REGISTER denemesi olmaz.
Gelen cagri (Task 13) ve TLS/SRTP **henuz kapsam disi**.

## Bilinen tuzaklar

Bu bolum gercekten yasanmis hatalari kaydediyor; degisiklik yaparken okuyun.

**Yapilandirma degisikligi gorunmuyorsa `--build` gerekiyor olabilir.**
`kamailio.cfg` ve `freeswitch/entrypoint.sh` image'a COPY edilir, bind-mount
EDILMEZ. `docker compose restart` bunlari almaz:

```bash
docker compose up -d --build kamailio     # veya freeswitch
```

`verify-08` adim 6 calisan Kamailio konfigurasyonunu repo ile karsilastirip
bu durumu yakalar.

**FreeSWITCH global degiskenlerine (`$${...}`) yapilandirma degeri baglamayin.**
`autoload_configs` alfabetik yuklenir; `sofia.conf.xml` ve dialplan,
`switch.conf.xml`'deki `<variables>` blogundan ONCE okunabilir ve deger bos
cozulur. `reloadxml` sonrasi duzeldigi icin fark edilmesi zordur. Bu yuzden
codec tercihleri ve trunk gateway adi `.env`'den sablona (`*.tmpl`) GOMULUR.

**Yeni bir `.env` degiskeni eklerken UC yer guncellenmeli:** `.env(.example)`,
`freeswitch/entrypoint.sh` icindeki `VARS` beyaz listesi, ve
`docker-compose.yml`'deki ilgili servisin `environment` blogu. Biri atlanirsa
envsubst bos string yazar ve ayar sessizce kaybolur.

**Port esitligi:** `FS_EXT_SIP_PORT` icin host portu = kapsayici portu olmak
zorunda. FreeSWITCH Contact/Via'ya profil portunu yazar ve `ext-sip-port` bu
derlemede Contact'i etkilemiyor; portlar ayri duserse dialog ici istekler
kaybolur.

**`${domain_name}` bu yiginda hic set edilmez** (kimlik dogrulama Kamailio'da,
FreeSWITCH directory'sinde degil). Dialplan'da `${sip_from_host}` kullanin.

**`mod_cdr_pg_csv` `<schema>` blogu olmadan yuklenmemeli** — alan listesi
olusmaz ve surec her cagri sonunda SIGSEGV verir.

**`git checkout` ile branch degistirdikten sonra kapsayicilari yenileyin.**
Checkout, bind-mount edilen dizinleri silip yeniden olusturabilir; kapsayici
eski inode'u tuttugu icin mount KOPAR ve dosyalar konteynerde kaybolur
(`No such file or directory`) — host'ta dururken. Cozum:

```bash
docker compose up -d --force-recreate
```

**Kamailio, FreeSWITCH'ten once baslayabilir ve bu NORMAL'dir.** compose'da
kamailio'nun freeswitch'e `depends_on`'u yok (karsilikli bagimlilik olurdu).
Dispatcher hedefi baslangicta cozumleme yaptigi icin bu durum eskiden butun
cagrilari kalici olarak 503 yapiyordu. Iki onlem birlikte gerekiyor:
`extra_hosts` ile `freeswitch` adinin sabit IP'ye eslenmesi VE
`use_dns_cache=0` (Kamailio kendi DNS onbellegini kullanirken `/etc/hosts`'u
ATLAR — konteyner icinde `getent hosts freeswitch` dogru sonuc verirken
Kamailio ayni adi cozemiyordu). `verify-94-startup-order.sh` bunu FreeSWITCH'i
durdurup Kamailio'yu yeniden baslatarak sinar.

**Sema degisikliklerini `db/init/` scriptlerine yazin.** Bu scriptler yalnizca
BOS bir veri dizininde calisir; calisan veritabanina elle `ALTER TABLE`
uygulamak yeterli degildir. `verify-92-fresh-schema.sh` init scriptlerini
gecici bir veritabaninda kosarak bunu dogrular.

## Hata ayiklama

```bash
# SIP trafigi (FreeSWITCH)
docker compose exec freeswitch fs_cli -p "$FS_ESL_PASSWORD" -x "sofia global siptrace on"
docker compose exec freeswitch tail -f /opt/freeswitch/var/log/freeswitch/freeswitch.log

# canli kayitlar (DB DEGIL: usrloc db_mode=2 write-back, tablo gecikmeli)
docker compose exec kamailio kamcmd ul.dump

# dispatcher hedefleri
docker compose exec kamailio kamcmd dispatcher.list

# canli, ayristirilmis FreeSWITCH konfigurasyonu (dosya degil, GERCEK deger)
docker compose exec freeswitch fs_cli -p "$FS_ESL_PASSWORD" -x "xml_locate configuration configuration name sofia.conf"

# CDR
docker compose exec postgres psql -U kamailio -d kamailio \
  -c "SELECT tenant_id,caller_id_number,destination_number,duration,billsec,hangup_cause FROM cdr ORDER BY id DESC LIMIT 10;"
```

`sip-call-probe.py` ve `sip-uas-probe.py` (`tools/`) softphone olmadan gercek
SIP cagrisi kurar; RTP echo'yu sayarak ses yolunu da dogrular.

## Bilinen sinirlar

- **Yarim kalan SIP akislari:** ACK gonderilmeyen cagrilarda gecmiste SIGSEGV
  gorulmustu; kok neden (`mod_cdr_pg_csv` semasi) giderildi ve
  `verify-08` adim 9 regresyon olarak izliyor.
- `trusted` ACL `172.16.0.0/12`'nin tamamina izin verir; ayni host'ta baska bir
  Docker projesi FreeSWITCH'in internal profiline ulasabilir.
- Event Socket (8021) yayinda; sunucuda guvenlik duvariyla kapatilmali.
- Ses KALITESI (jitter, kopma) otomatik olcumu yok — kulakla dogrulanir.
- Gelen trunk cagrisi, TLS/SRTP, voicemail, IVR kapsam disi.

## Dizin yapisi

```
db/init/          sema + seed (yalnizca bos veri dizininde calisir)
kamailio/         Dockerfile + kamailio.cfg (image'a gomulu)
freeswitch/       Dockerfile, entrypoint.sh, conf/ (*.tmpl -> render), scripts/
xmlapi/           tenant-aware directory + dialplan (mod_xml_curl)
scripts/          verify-*.sh dogrulama scriptleri
tools/            add-user.sh, sip-call-probe.py, sip-uas-probe.py
```
