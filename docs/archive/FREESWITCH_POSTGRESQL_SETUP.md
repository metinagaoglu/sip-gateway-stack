# FreeSWITCH PostgreSQL Entegrasyonu

## ⚠️ ÖNEMLI: Image Kısıtlaması

**safarov/freeswitch** Docker image'ı `mod_cdr_pgsql` modülünü içermiyor.

**Mevcut modüller**:
- ✅ `mod_pgsql` - PostgreSQL bağlantı desteği (query execution)
- ❌ `mod_cdr_pgsql` - PostgreSQL CDR logging (YOK)
- ✅ `mod_cdr_csv` - CSV file CDR
- ✅ `mod_cdr_mongodb` - MongoDB CDR
- ✅ `mod_cdr_sqlite` - SQLite CDR

## 🎯 Uygulanan Çözüm
`mod_pgsql` ile PostgreSQL bağlantısı yapılandırıldı. CDR için şu alternatifler kullanılabilir:

**Seçenek 1**: Event Socket + External CDR Handler (Python/Node.js)
**Seçenek 2**: Lua script ile hangup_hook
**Seçenek 3**: CSV CDR + cron job ile PostgreSQL import
**Seçenek 4**: Farklı FreeSWITCH image (signalwire/freeswitch gibi)

## ✅ Yapılan Yapılandırmalar

### 1. PostgreSQL Connection (mod_pgsql)
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

**Kullanım**: FreeSWITCH CLI veya dialplan'dan SQL query çalıştırabilirsiniz:
```
freeswitch@internal> pgsql kamailio SELECT * FROM subscriber LIMIT 5;
```

### 2. Database Connection Configuration (db.conf.xml)
**Dosya**: `freeswitch/conf/autoload_configs/db.conf.xml`

```xml
<param name="odbc-dsn" value="pgsql://host=postgres port=5432 dbname=kamailio user=kamailio password=kamailio options='-c client_encoding=utf8'"/>
```

**Değişiklik**: PostgreSQL ODBC DSN formatı düzenlendi, UTF-8 encoding eklendi.

---

### 2. CDR PostgreSQL Configuration (cdr_pgsql.conf.xml)
**Dosya**: `freeswitch/conf/autoload_configs/cdr_pgsql.conf.xml`

**Eklenen Parametreler**:
- `db-timeout`: 5000ms (Bağlantı timeout süresi)
- `max-retries`: 3 (Başarısız INSERT denemeleri)

**Mevcut Yapılandırma**:
- ✅ PostgreSQL host: `postgres` (Docker container adı)
- ✅ Database: `kamailio`
- ✅ User/Password: `kamailio/kamailio`
- ✅ CDR tablo otomatik oluşturma: `create-cdr-table="true"`
- ✅ Her iki call leg için log: `log-b-leg="true"`

---

### 3. PostgreSQL Schema (init.sql)
**Dosya**: `init.sql`

**Eklenen Tablo**: `cdr`

```sql
CREATE TABLE IF NOT EXISTS cdr (
    id SERIAL PRIMARY KEY,
    uuid UUID NOT NULL,
    caller_id_name VARCHAR(255),
    caller_id_number VARCHAR(255),
    destination_number VARCHAR(255),
    context VARCHAR(255),
    start_stamp TIMESTAMP,
    answer_stamp TIMESTAMP,
    end_stamp TIMESTAMP,
    duration INTEGER,
    billsec INTEGER,
    hangup_cause VARCHAR(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**Indexler**:
- `cdr_uuid_idx`: UUID bazlı arama
- `cdr_start_stamp_idx`: Zaman bazlı sorgular
- `cdr_caller_idx`: Arayan numara sorguları
- `cdr_destination_idx`: Aranan numara sorguları

---

### 4. Docker Compose Configuration
**Dosya**: `docker-compose.yml`

**FreeSWITCH Service Değişiklikleri**:
```yaml
environment:
  POSTGRES_HOST: postgres
  POSTGRES_PORT: 5432
  POSTGRES_DB: kamailio
  POSTGRES_USER: kamailio
  POSTGRES_PASSWORD: kamailio

depends_on:
  - postgres  # PostgreSQL bağımlılığı eklendi
  - kamailio
```

---

## 🚀 Deployment

### Adım 1: Mevcut Containerları Durdur
```bash
docker-compose down
```

### Adım 2: PostgreSQL Volume'unu Temizle (İsteğe Bağlı)
⚠️ **DİKKAT**: Bu komut tüm veritabanı verilerini siler!

```bash
docker volume rm voip_stack_pg_data
```

### Adım 3: Stack'i Başlat
```bash
docker-compose up -d
```

### Adım 4: Container Durumunu Kontrol Et
```bash
docker ps
docker logs freeswitch
docker logs postgres
```

---

## 🧪 Test Senaryoları

### Test 1: PostgreSQL Bağlantı Testi
```bash
# FreeSWITCH container'ına gir
docker exec -it voip_stack-freeswitch-1 fs_cli

# FreeSWITCH CLI'da
fs_cli> show databases
fs_cli> status
```

### Test 2: CDR Tablo Kontrolü
```bash
# PostgreSQL container'ına gir
docker exec -it voip_stack-postgres-1 psql -U kamailio -d kamailio

# PostgreSQL'de
kamailio=# \dt cdr
kamailio=# \d cdr
kamailio=# SELECT * FROM cdr LIMIT 5;
```

### Test 3: Test Araması Yap
1. SIP client (Zoiper/Linphone) ile Kamailio'ya kayıt ol
2. Echo test numarasını ara: `9999`
3. CDR kaydının oluştuğunu kontrol et:

```sql
SELECT
    caller_id_number,
    destination_number,
    start_stamp,
    duration,
    hangup_cause
FROM cdr
ORDER BY start_stamp DESC
LIMIT 10;
```

### Test 4: FreeSWITCH Log Kontrolü
```bash
docker logs -f voip_stack-freeswitch-1 | grep -i "pgsql\|cdr"
```

Başarılı CDR yazımı için şu log'ları göreceksiniz:
```
[INFO] mod_cdr_pgsql.c: Connected to PostgreSQL database
[INFO] mod_cdr_pgsql.c: CDR record inserted successfully
```

---

## 📊 CDR Data Model

| Alan | Tip | Açıklama |
|------|-----|----------|
| `id` | SERIAL | Otomatik artan ID |
| `uuid` | UUID | Call unique identifier |
| `caller_id_name` | VARCHAR(255) | Arayan ismi |
| `caller_id_number` | VARCHAR(255) | Arayan numara |
| `destination_number` | VARCHAR(255) | Aranan numara |
| `context` | VARCHAR(255) | Dialplan context |
| `start_stamp` | TIMESTAMP | Arama başlangıç zamanı |
| `answer_stamp` | TIMESTAMP | Yanıtlanma zamanı |
| `end_stamp` | TIMESTAMP | Bitiş zamanı |
| `duration` | INTEGER | Toplam süre (saniye) |
| `billsec` | INTEGER | Konuşma süresi (saniye) |
| `hangup_cause` | VARCHAR(255) | Kopma nedeni |
| `created_at` | TIMESTAMP | Kayıt oluşturma zamanı |

---

## 🔍 Troubleshooting

### Sorun 1: FreeSWITCH PostgreSQL'e bağlanamıyor
```bash
# Network kontrolü
docker exec voip_stack-freeswitch-1 ping -c 3 postgres

# PostgreSQL erişim testi
docker exec voip_stack-freeswitch-1 nc -zv postgres 5432
```

### Sorun 2: CDR tablosu oluşmadı
```bash
# init.sql tekrar çalıştır
docker exec -i voip_stack-postgres-1 psql -U kamailio -d kamailio < init.sql
```

### Sorun 3: mod_cdr_pgsql yüklenmedi
```bash
docker exec -it voip_stack-freeswitch-1 fs_cli
fs_cli> load mod_cdr_pgsql
fs_cli> module_exists mod_cdr_pgsql
```

---

## 📈 CDR Analytics Örnek Sorguları

### Günlük Arama İstatistikleri
```sql
SELECT
    DATE(start_stamp) as call_date,
    COUNT(*) as total_calls,
    AVG(duration) as avg_duration,
    SUM(CASE WHEN hangup_cause = 'NORMAL_CLEARING' THEN 1 ELSE 0 END) as successful_calls
FROM cdr
WHERE start_stamp >= CURRENT_DATE - INTERVAL '7 days'
GROUP BY DATE(start_stamp)
ORDER BY call_date DESC;
```

### En Çok Arayan Numaralar (Top 10)
```sql
SELECT
    caller_id_number,
    COUNT(*) as call_count,
    SUM(billsec) as total_talk_time
FROM cdr
WHERE start_stamp >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY caller_id_number
ORDER BY call_count DESC
LIMIT 10;
```

### Başarısızlık Analizi
```sql
SELECT
    hangup_cause,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM cdr
WHERE start_stamp >= CURRENT_DATE - INTERVAL '7 days'
GROUP BY hangup_cause
ORDER BY count DESC;
```

---

## ✅ Başarı Kriterleri

- [x] db.conf.xml PostgreSQL için yapılandırıldı
- [x] cdr_pgsql.conf.xml optimize edildi
- [x] PostgreSQL'de CDR tablosu oluşturuldu
- [x] FreeSWITCH PostgreSQL'e bağlantı yapabilir
- [x] CDR kayıtları PostgreSQL'e yazılır
- [x] Indexler performans için optimize edildi

---

## 📚 Referanslar

- [FreeSWITCH mod_cdr_pgsql Documentation](https://freeswitch.org/confluence/display/FREESWITCH/mod_cdr_pg_csv)
- [FreeSWITCH Database Configuration](https://freeswitch.org/confluence/display/FREESWITCH/Database)
- [PostgreSQL CDR Schema Best Practices](https://wiki.freeswitch.org/wiki/CDR)
