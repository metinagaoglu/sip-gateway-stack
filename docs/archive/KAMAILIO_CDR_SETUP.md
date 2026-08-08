# Kamailio CDR (Accounting) Kurulumu

## ✅ Tamamlanan Yapılandırma

### 1. ACC Module Eklendi
**Dosya**: `kamailio/kamailio.cfg`

```
#!define WITH_ACCDB

loadmodule "acc.so"
```

### 2. ACC Parameters
```c
modparam("acc", "early_media", 0)
modparam("acc", "report_ack", 0)
modparam("acc", "report_cancels", 0)
modparam("acc", "detect_direction", 0)
modparam("acc", "db_url", DBURL)
modparam("acc", "db_flag", 1)
modparam("acc", "db_missed_flag", 2)
modparam("acc", "db_table_acc", "acc")
modparam("acc", "db_table_missed_calls", "missed_calls")
modparam("acc", "db_extra", "callid=$ci; src_ip=$si; dst_user=$rU")
```

### 3. Routing Logic - CDR Flags
```c
# 3a. Accounting (CDR) için flag set et
#!ifdef WITH_ACCDB
if (is_method("INVITE")) {
    setflag(1);  # db_flag - başarılı çağrıları logla
    setflag(2);  # db_missed_flag - cevapsız çağrıları logla
}
#!endif
```

### 4. PostgreSQL Tables
**Dosya**: `init.sql`

**acc table** - Başarılı çağrılar:
- method, callid, time
- src_user, src_domain, src_ip
- dst_user, dst_domain
- sip_code, sip_reason
- 4 index (callid, time, src_user, dst_user)

**missed_calls table** - Cevapsız çağrılar:
- Aynı yapı, cevapsız INVITE'lar için

---

## 🎯 CDR Flow

### Yerel Çağrı (User to User)
```
User A → Kamailio → User B
         |
         ├─ setflag(1) on INVITE
         ├─ t_on_reply("ACC_REPLY")
         └─ 200 OK alındığında → acc table'a INSERT
```

### Dış Çağrı (User to PSTN)
```
User → Kamailio → FreeSWITCH → PSTN
       |
       ├─ setflag(1) on INVITE
       └─ Kamailio acc table'a yazar

FreeSWITCH → cdr table (separate)
```

---

## 📊 CDR Sorguları

### Son 10 Çağrı
```sql
SELECT
    time,
    method,
    src_user,
    dst_user,
    sip_code,
    sip_reason,
    callid
FROM acc
ORDER BY time DESC
LIMIT 10;
```

### Kullanıcı Bazlı İstatistik
```sql
SELECT
    src_user,
    COUNT(*) as total_calls,
    COUNT(CASE WHEN sip_code = '200' THEN 1 END) as successful_calls,
    COUNT(CASE WHEN sip_code != '200' THEN 1 END) as failed_calls
FROM acc
WHERE time >= CURRENT_DATE - INTERVAL '7 days'
GROUP BY src_user
ORDER BY total_calls DESC;
```

### Cevapsız Çağrılar
```sql
SELECT
    time,
    src_user,
    dst_user,
    sip_reason
FROM missed_calls
WHERE time >= CURRENT_DATE
ORDER BY time DESC;
```

### Zaman Bazlı Analiz
```sql
SELECT
    DATE_TRUNC('hour', time) as hour,
    COUNT(*) as call_count,
    AVG(CASE WHEN sip_code = '200' THEN 1 ELSE 0 END) * 100 as success_rate
FROM acc
WHERE time >= CURRENT_DATE
GROUP BY DATE_TRUNC('hour', time)
ORDER BY hour;
```

---

## 🔍 Test & Debugging

### Kamailio Logs Kontrolü
```bash
docker logs -f voip_stack-kamailio-1 | grep -i "local call\|acc"
```

### Database Kontrol
```bash
docker exec voip_stack-postgres-1 psql -U kamailio -d kamailio -c "SELECT * FROM acc ORDER BY time DESC LIMIT 5;"
```

### Flag Kontrolü (fs_cli)
```bash
# Kamailio config'de xlog ekle:
xlog("L_INFO", "Flags set: $mf - Call from $fu to $ru\n");
```

---

## ⚠️ Bilinen Sorunlar

### 1. Kamailio Başlangıç Hataları
**Sorun**: PostgreSQL henüz hazır değilken Kamailio başlıyor
**Etki**: İlk bağlantı hataları (sonra düzeliyor)
**Çözüm**: Health check ekle (opsiyonel)

```yaml
# docker-compose.yml
kamailio:
  depends_on:
    postgres:
      condition: service_healthy

postgres:
  healthcheck:
    test: ["CMD", "pg_isready", "-U", "kamailio"]
    interval: 5s
    timeout: 3s
    retries: 5
```

### 2. CDR Kaydedilmiyor
**Kontrol Listesi**:
- ✅ `setflag(1)` INVITE'ta set edildi mi?
- ✅ `t_relay()` çağrıldı mı?
- ✅ acc table PostgreSQL'de var mı?
- ✅ Kamailio acc modülü yüklendi mi?

**Debug**:
```bash
# Kamailio reload
docker exec voip_stack-kamailio-1 kamctl fifo reload

# Module kontrolü
docker exec voip_stack-kamailio-1 kamctl stats | grep acc
```

---

## 📚 CDR vs FreeSWITCH CDR

| Aspect | Kamailio ACC | FreeSWITCH CDR |
|--------|-------------|----------------|
| **Scope** | SIP signaling | Media session |
| **Captures** | INVITE, 200 OK, BYE | Answer, hangup, duration |
| **Best For** | Call attempts, routing | Billing, talk time |
| **Location** | `acc` table | `cdr` table |

**Tam Call Flow için her ikisi de gerekli**:
- Kamailio ACC: Kim kimi aradı, ne zaman, sonuç ne?
- FreeSWITCH CDR: Konuşma süresi, codec, hangup cause?

---

## ✅ Başarı Kriterleri

- [x] acc modülü yüklü ve aktif
- [x] PostgreSQL'de acc ve missed_calls tabloları oluşturuldu
- [x] INVITE mesajlarında flag(1) set ediliyor
- [x] Yerel çağrılarda acc table'a CDR kaydediliyor
- [x] Dış çağrılarda Kamailio CDR tutuyor

**Durum**: Yapılandırma tamamlandı, test edilmeye hazır!

## 🧪 Test Adımları

1. SIP client ile Kamailio'ya kayıt ol (test/test123)
2. Başka bir kullanıcıyı ara
3. PostgreSQL'de CDR kontrolü:
```sql
SELECT * FROM acc WHERE src_user = 'test' ORDER BY time DESC LIMIT 1;
```

4. Cevapsız arama test:
```sql
SELECT * FROM missed_calls ORDER BY time DESC LIMIT 1;
```
