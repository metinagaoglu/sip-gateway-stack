# Quick Start: PostgreSQL-Centric VoIP Stack

## ⚠️ Mevcut Durum

Şu anda **doğrudan build etsen çalışmaz** çünkü:

### ❌ Sorunlar:
1. `docker-compose.yml` hala eski `init.sql` kullanıyor (yeni schema değil)
2. FreeSWITCH `modules.conf.xml` hala eski (xml_curl ve cdr_pgsql yüklü değil)
3. XML API servisi mevcut compose'da yok

### ✅ Hazır Olanlar:
- ✅ `init_full_pgsql.sql` - Yeni unified schema
- ✅ `xmlapi/` - Flask XML API service (Dockerfile, app.py)
- ✅ `docker-compose.pgsql.yml` - XML API ile güncellenmiş
- ✅ `xml_curl.conf.xml` - FreeSWITCH XML Curl config
- ✅ `modules.conf.pgsql.xml` - PostgreSQL modülleri aktif
- ✅ `cdr_pgsql.conf.xml` - CDR configuration
- ✅ `pgsql.conf.xml` - PostgreSQL connection

---

## 🚀 Çalışır Hale Getirme (3 Seçenek)

### Seçenek 1: Hızlı Test (Recommended) ⚡

Yeni sistemi test etmek için **eski sistemi etkilemeden**:

```bash
# 1. Yeni compose ile başlat
docker-compose -f docker-compose.pgsql.yml up -d postgres

# 2. Database'in hazır olmasını bekle
docker-compose -f docker-compose.pgsql.yml logs -f postgres
# "Schema Created Successfully" mesajını gördükten sonra Ctrl+C

# 3. XML API'yi başlat
docker-compose -f docker-compose.pgsql.yml up -d xmlapi

# 4. XML API'yi test et
curl http://localhost:8080/health

# 5. FreeSWITCH config güncelle (geçici)
docker-compose -f docker-compose.pgsql.yml build freeswitch

# 6. Tüm servisleri başlat
docker-compose -f docker-compose.pgsql.yml up -d

# 7. Logları izle
docker-compose -f docker-compose.pgsql.yml logs -f
```

**Avantajlar**:
- Eski sisteme dokunmaz
- Sorun olursa geri dönebilirsin
- Test edip sonra karar verebilirsin

---

### Seçenek 2: Tam Geçiş (Production)

Eski sistemden yeni sisteme tam geçiş:

```bash
# 0. Backup al (önemli!)
docker-compose exec postgres pg_dump -U kamailio kamailio > backup_$(date +%Y%m%d).sql

# 1. Eski sistemi durdur
docker-compose down

# 2. PostgreSQL volume'ü temizle (DİKKAT: Veri kaybı!)
docker volume rm voip_stack_pg_data

# 3. Yeni compose'u aktif et
mv docker-compose.yml docker-compose.old.yml
cp docker-compose.pgsql.yml docker-compose.yml

# 4. FreeSWITCH modules'ü güncelle
cp freeswitch/conf/autoload_configs/modules.conf.pgsql.xml \
   freeswitch/conf/autoload_configs/modules.conf.xml

# 5. Sistemi başlat
docker-compose up -d

# 6. Logları kontrol et
docker-compose logs -f
```

**Avantajlar**:
- Production-ready sistem
- Unified PostgreSQL
- Multi-tenant desteği

**Dezavantajlar**:
- Eski data kaybolur (backup aldıysan sorun yok)
- Geri dönüş biraz daha zor

---

### Seçenek 3: Minimal Değişiklik (En Güvenli)

Sadece eksikleri tamamla, eski sistemi koru:

```bash
# 1. Sadece XML API ekle (eski compose'u güncelle)
# docker-compose.yml dosyasına xmlapi service'i manuel ekle

# 2. FreeSWITCH'e xml_curl modülü ekle
# modules.conf.xml'e ekle: <load module="mod_xml_curl"/>

# 3. Rebuild
docker-compose build freeswitch
docker-compose up -d xmlapi freeswitch

# 4. Test
curl http://localhost:8080/health
```

**Avantajlar**:
- Minimum değişiklik
- Mevcut data korunur
- Adım adım geçiş

**Dezavantajlar**:
- Eski schema'da tenant desteği yok
- Manuel migration gerekebilir

---

## ✅ Önerilen Yol: Seçenek 1 (Hızlı Test)

En güvenli ve hızlı yol:

### Adım 1: Test Et
```bash
# Test compose ile başlat
docker-compose -f docker-compose.pgsql.yml up -d
```

### Adım 2: Doğrula
```bash
# Database kontrol
docker exec postgres psql -U kamailio -d kamailio -c \
  "SELECT id, tenant_code, domain FROM tenants;"

# XML API kontrol
curl http://localhost:8080/health

# XML API directory test
curl -X POST http://localhost:8080/fs/directory \
  -d "user=alice" \
  -d "domain=tenant1.voip.local"
```

### Adım 3: SIP Test
SIP client ile test:
- Username: `alice`
- Domain: `tenant1.voip.local`
- Password: `alice123`
- Server: `localhost:5060`

### Adım 4: Karar Ver
Eğer çalışıyorsa:
```bash
# Eski sistemi kapat
docker-compose down

# Yeni sistemi production yap
mv docker-compose.yml docker-compose.old.yml
cp docker-compose.pgsql.yml docker-compose.yml

# Normal şekilde çalıştır
docker-compose up -d
```

---

## 🔍 Kontrol Listesi

Test ederken şunları kontrol et:

### Database
```bash
docker exec postgres psql -U kamailio -d kamailio -c \
  "SELECT table_name FROM information_schema.tables WHERE table_schema='public';"
```

Olması gerekenler:
- ✅ `tenants`
- ✅ `subscriber` (tenant_id kolonu ile)
- ✅ `dialplan`
- ✅ `fs_directory` (view)
- ✅ `fs_dialplan` (view)

### XML API
```bash
# Health check
curl http://localhost:8080/health

# Directory lookup (alice)
curl -X POST http://localhost:8080/fs/directory \
  -d "user=alice" \
  -d "domain=tenant1.voip.local"

# Dialplan lookup (9999 - echo test)
curl -X POST http://localhost:8080/fs/dialplan \
  -d "Hunt-Context=default" \
  -d "Hunt-Destination-Number=9999"
```

### FreeSWITCH
```bash
# CLI'ye bağlan
docker exec -it freeswitch fs_cli

# Modül kontrolü
freeswitch> module_exists mod_xml_curl
freeswitch> module_exists mod_cdr_pgsql
freeswitch> module_exists mod_pgsql

# XML Curl test (user lookup)
freeswitch> xml_locate directory alice@tenant1.voip.local

# Exit
freeswitch> exit
```

### Kamailio
```bash
# Location table kontrol
docker exec postgres psql -U kamailio -d kamailio -c \
  "SELECT username, domain, contact FROM location WHERE expires > NOW();"
```

---

## ⚠️ Bilinen Sorunlar ve Çözümleri

### Sorun 1: XML API bağlanamıyor PostgreSQL'e
```bash
# Logları kontrol et
docker-compose logs xmlapi

# Database connection test
docker exec xmlapi python3 -c "
import psycopg2
conn = psycopg2.connect(host='postgres', database='kamailio', user='kamailio', password='kamailio')
print('OK')
"
```

### Sorun 2: FreeSWITCH xml_curl hata veriyor
```bash
# xml_curl.conf.xml'i kontrol et
docker exec freeswitch cat /opt/freeswitch/conf/autoload_configs/xml_curl.conf.xml

# URL'i test et
docker exec freeswitch curl http://xmlapi:8080/health
```

### Sorun 3: CDR kaydedilmiyor
```bash
# mod_cdr_pgsql yüklü mü?
docker exec freeswitch fs_cli -x "module_exists mod_cdr_pgsql"

# CDR table var mı?
docker exec postgres psql -U kamailio -d kamailio -c "SELECT * FROM cdr LIMIT 1;"
```

---

## 📊 Test Sonuçları

Build edip test ettikten sonra:

### ✅ Başarılı ise:
- Tüm modüller yüklendi
- XML API çalışıyor
- Database bağlantıları OK
- SIP registration çalışıyor
- CDR kaydediliyor

### ❌ Başarısız ise:
Hangi adımda hata aldın? Logları paylaş:
```bash
docker-compose logs xmlapi > xmlapi.log
docker-compose logs freeswitch > freeswitch.log
docker-compose logs kamailio > kamailio.log
docker-compose logs postgres > postgres.log
```

---

## 🎯 Özet

**Şu anda build etsen çalışır mı?**
→ Hayır, önce yukarıdaki adımlardan birini yapmalısın.

**En kolay yol?**
→ Seçenek 1: `docker-compose -f docker-compose.pgsql.yml up -d`

**Production için?**
→ Seçenek 2: Tam geçiş (backup al önce!)

**Sorularım varsa?**
→ Logları paylaş, adım adım gideriz.
