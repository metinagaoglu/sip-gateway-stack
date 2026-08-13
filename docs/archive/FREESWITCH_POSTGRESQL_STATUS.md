# FreeSWITCH PostgreSQL Entegrasyon Durumu

## ✅ Tamamlanan İşlemler

### 1. Dockerfile Düzenlendi
**Sorun**: Config dosyaları yanlış sırada kopyalanıyordu (vanilla config'ler custom config'lerin üzerine yazıyordu)

**Çözüm**:
```dockerfile
# Custom config dosyalarını /usr/share altına kopyala
# Entrypoint script bunları /etc/freeswitch'e kopyalayacak
COPY conf/ /usr/share/freeswitch/conf/vanilla/
```

### 2. PostgreSQL Bağlantı Yapılandırması
**Dosya**: `freeswitch/conf/autoload_configs/pgsql.conf.xml`

```xml
<connection name="kamailio">
  <param name="hostname" value="postgres"/>
  <param name="hostport" value="5432"/>
  <param name="username" value="kamailio"/>
  <param name="password" value="kamailio"/>
  <param name="dbname" value="kamailio"/>
</connection>
```

**Durum**: ✅ Yapılandırma container'a başarıyla kopyalandı
**Modül**: ✅ `mod_pgsql` başarıyla yüklendi

### 3. Database Schema
**Dosya**: `init.sql`

CDR tablosu ve indexler eklendi:
- `cdr` table (11 field)
- 4 performance index (uuid, start_stamp, caller, destination)

**Durum**: ✅ Tablo PostgreSQL'de oluşturuldu

### 4. Docker Compose
FreeSWITCH environment variables ve PostgreSQL dependency eklendi:

```yaml
environment:
  POSTGRES_HOST: postgres
  POSTGRES_PORT: 5432
  POSTGRES_DB: kamailio
  POSTGRES_USER: kamailio
  POSTGRES_PASSWORD: kamailio
depends_on:
  - postgres
```

**Durum**: ✅ Container başarıyla başlatıldı

---

## ⚠️ Kısıt: CDR Module Eksik

**safarov/freeswitch** image'ında `mod_cdr_pgsql` modülü YOK.

**Mevcut Durumu**:
- ✅ `mod_pgsql` - PostgreSQL connection (yüklü ve çalışıyor)
- ❌ `mod_cdr_pgsql` - Otomatik CDR logging (YOK)
- ✅ `mod_pgsql` database backend olarak çalışıyor ama CLI/API expose etmiyor

---

## 🎯 CDR için Alternatif Çözümler

### Seçenek 1: CSV CDR + Cron Job (En Basit)
```xml
<!-- modules.conf.xml -->
<load module="mod_cdr_csv"/>
```

```bash
# Cron job: Her 5 dakikada CSV'yi PostgreSQL'e import et
*/5 * * * * /usr/local/bin/csv_to_postgres.sh
```

**Artılar**: Kolay implement, güvenilir
**Eksiler**: Real-time değil (5 dk delay)

---

### Seçenek 2: Event Socket + External Handler (Tavsiye Edilen)
Python/Node.js script ile FreeSWITCH events dinle ve PostgreSQL'e yaz.

**Python Örneği**:
```python
import ESL
import psycopg2

conn = ESL.ESLconnection('freeswitch', '8021', 'ClueCon')
conn.events('plain', 'CHANNEL_HANGUP_COMPLETE')

while conn.connected():
    event = conn.recvEvent()
    if event:
        # PostgreSQL'e CDR kaydet
        cursor.execute("INSERT INTO cdr ...")
```

**Artılar**: Real-time, esnek, maintenance kolay
**Eksiler**: External service gerekir (Python container ekle)

---

### Seçenek 3: Farklı FreeSWITCH Image (Uzun Vadeli Çözüm)
`signalwire/freeswitch` veya custom build image kullan (mod_cdr_pgsql ile).

**Dockerfile**:
```dockerfile
FROM debian:bullseye
RUN apt-get install -y freeswitch freeswitch-mod-cdr-pgsql
```

**Artılar**: Native CDR support
**Eksiler**: Rebuild gerekir, image büyüklüğü

---

## 📊 Mevcut Sistem Özeti

| Component | Status | Notes |
|-----------|--------|-------|
| PostgreSQL | ✅ Running | kamailio DB + cdr table |
| FreeSWITCH | ✅ Running | mod_pgsql loaded |
| db.conf.xml | ✅ Configured | ODBC DSN format |
| pgsql.conf.xml | ✅ Configured | Connection: postgres:5432 |
| CDR Table | ✅ Created | 4 indexes, ready for use |
| mod_cdr_pgsql | ❌ Missing | Not in safarov/freeswitch image |

---

## 🚀 Tavsiye: Event Socket CDR Handler

**Neden**:
1. Real-time CDR logging
2. External service olarak ölçeklenebilir
3. FreeSWITCH image değiştirmeden çalışır
4. Python/Node.js ile kolay maintenance

**Implementation Plan**:
1. Python container ekle (docker-compose.yml)
2. ESL library ile Event Socket'e bağlan
3. CHANNEL_HANGUP_COMPLETE events dinle
4. psycopg2 ile PostgreSQL'e CDR kaydet
5. Error handling + retry logic

**Örnek docker-compose.yml eklenti**:
```yaml
cdr_handler:
  build: ./cdr_handler
  depends_on:
    - freeswitch
    - postgres
  environment:
    FS_HOST: freeswitch
    FS_PORT: 8021
    FS_PASSWORD: ClueCon
    POSTGRES_DSN: postgresql://kamailio:kamailio@postgres:5432/kamailio
  networks:
    - voip_net
```

---

## ✅ Sonuç

**FreeSWITCH artık PostgreSQL'e bağlanabiliyor** ✅

- Database connection: ✅ Çalışıyor
- CDR table: ✅ Hazır
- Otomatik CDR logging: ⚠️ External handler gerekiyor

**Şu an için**: FreeSWITCH `mod_pgsql` ile PostgreSQL'i database backend olarak kullanabilir (dialplan queries, user lookup vb).

**CDR için**: Event Socket CDR handler implement etmek tavsiye edilir (30-50 satır Python kodu).
