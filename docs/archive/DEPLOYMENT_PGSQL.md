# PostgreSQL-Centric Multi-Tenant VoIP Stack - Deployment Guide

## 🎯 Objective

Deploy a unified PostgreSQL-based multi-tenant VoIP system where:
- ✅ **All user data** lives in PostgreSQL
- ✅ **Kamailio** authenticates users from PostgreSQL
- ✅ **FreeSWITCH** gets user directory from PostgreSQL
- ✅ **Multi-tenancy** via prefix (`1234*alice`) or domain (`alice@tenant1.voip.local`)
- ✅ **Unified CDR** in single database

---

## 📊 Architecture Summary

```
┌─────────────────────────────────────────────┐
│         PostgreSQL (Single DB)              │
│  • tenants (multi-tenant config)            │
│  • subscriber (unified users)               │
│  • dialplan (routing rules)                 │
│  • acc + cdr (unified CDR)                  │
└─────────────────────────────────────────────┘
     ↓                 ↓                  ↓
┌──────────┐    ┌──────────┐    ┌──────────────┐
│ Kamailio │←───│ XML API  │←───│  FreeSWITCH  │
│  (Auth)  │    │ (Flask)  │    │  (Media)     │
└──────────┘    └──────────┘    └──────────────┘
```

**Key Components**:
1. **PostgreSQL**: Single source of truth for all data
2. **XML API Service**: Flask app serving FreeSWITCH directory/dialplan from PostgreSQL
3. **Kamailio**: SIP proxy with PostgreSQL authentication
4. **FreeSWITCH**: Media gateway using PostgreSQL via XML API

---

## 📦 What's Been Created

### 1. Database Schema
**File**: `init_full_pgsql.sql`

**Tables**:
- `tenants` → Multi-tenant configuration
- `subscriber` → Unified user database (Kamailio + FreeSWITCH)
- `location` → SIP registrations
- `dialplan` → Database-driven routing rules
- `acc`, `cdr`, `missed_calls` → Unified CDR

**Views**:
- `fs_directory` → FreeSWITCH user authentication
- `fs_dialplan` → FreeSWITCH routing rules

**Sample Data**:
- 2 tenants (1234, 5678)
- 3 test users (alice, bob, charlie)
- Sample dialplan rules

### 2. XML API Service
**Directory**: `xmlapi/`

**Files**:
- `app.py` → Flask application serving FreeSWITCH XML
- `Dockerfile` → Container image
- `requirements.txt` → Python dependencies

**Endpoints**:
- `GET/POST /fs/directory` → User authentication
- `GET/POST /fs/dialplan` → Routing rules
- `GET /health` → Health check

### 3. Configuration Files

**FreeSWITCH**:
- `xml_curl.conf.xml` → XML Curl configuration
- `modules.conf.pgsql.xml` → Modules with PostgreSQL enabled
- `cdr_pgsql.conf.xml` → CDR to PostgreSQL

**Docker**:
- `docker-compose.pgsql.yml` → Updated compose file with XML API

---

## 🚀 Deployment Steps

### Step 1: Backup Current Data (Optional)

```bash
# Backup existing database
docker exec voip_stack-postgres-1 pg_dump -U kamailio kamailio > backup_$(date +%Y%m%d).sql

# Backup current config
cp docker-compose.yml docker-compose.yml.backup
```

### Step 2: Deploy New Database Schema

```bash
# Stop all containers
docker-compose down

# Remove old PostgreSQL volume (CAUTION: Data loss!)
docker volume rm voip_stack_pg_data

# Use new docker-compose file
cp docker-compose.pgsql.yml docker-compose.yml

# Start PostgreSQL first
docker-compose up -d postgres

# Watch logs to verify schema creation
docker-compose logs -f postgres
```

**Expected output**:
```
============================================================================
VoIP Stack - Full PostgreSQL Schema Created Successfully!
============================================================================

Multi-Tenant Configuration:
  - Tenant 1: code=1234, domain=tenant1.voip.local
  - Tenant 2: code=5678, domain=tenant2.voip.local
...
```

### Step 3: Build and Start XML API Service

```bash
# Build XML API image
docker-compose build xmlapi

# Start XML API
docker-compose up -d xmlapi

# Verify it's running
docker-compose logs xmlapi

# Test health endpoint
curl http://localhost:8080/health
```

**Expected response**:
```json
{
  "status": "healthy",
  "database": "connected"
}
```

### Step 4: Update FreeSWITCH Modules

```bash
# Replace modules configuration
cp freeswitch/conf/autoload_configs/modules.conf.pgsql.xml \
   freeswitch/conf/autoload_configs/modules.conf.xml

# Rebuild FreeSWITCH image
docker-compose build freeswitch
```

### Step 5: Start All Services

```bash
# Start remaining services
docker-compose up -d

# Check all containers are running
docker-compose ps

# Watch logs
docker-compose logs -f
```

### Step 6: Verify Database

```bash
# Connect to PostgreSQL
docker exec -it postgres psql -U kamailio -d kamailio

# Check tenants
SELECT id, tenant_code, domain, name FROM tenants;

# Check users
SELECT username, domain, tenant_id, enabled FROM subscriber;

# Check FreeSWITCH directory view
SELECT "user", domain, tenant_code FROM fs_directory;

# Exit
\q
```

**Expected output**:
```
 id | tenant_code |       domain        |   name
----+-------------+---------------------+----------
  1 | 1234        | tenant1.voip.local  | Tenant 1
  2 | 5678        | tenant2.voip.local  | Tenant 2

    user    |       domain        | tenant_code
------------+---------------------+-------------
 alice      | tenant1.voip.local  | 1234
 bob        | tenant1.voip.local  | 1234
 charlie    | tenant2.voip.local  | 5678
```

---

## 🧪 Testing

### Test 1: XML API Directory Lookup

```bash
# Test alice@tenant1.voip.local
curl -X POST http://localhost:8080/fs/directory \
  -d "user=alice" \
  -d "domain=tenant1.voip.local"
```

**Expected**: XML document with alice's authentication data

### Test 2: XML API Dialplan Lookup

```bash
# Test dialplan for 9999 (echo test)
curl -X POST http://localhost:8080/fs/dialplan \
  -d "Hunt-Context=default" \
  -d "Hunt-Destination-Number=9999"
```

**Expected**: XML with echo test dialplan

### Test 3: FreeSWITCH Directory Integration

```bash
# Access FreeSWITCH CLI
docker exec -it freeswitch fs_cli

# Test user lookup
freeswitch> xml_locate directory alice@tenant1.voip.local

# Check modules
freeswitch> module_exists mod_xml_curl
freeswitch> module_exists mod_cdr_pgsql

# Exit
freeswitch> exit
```

### Test 4: SIP Registration

**Using SIP Client** (e.g., Zoiper, Linphone):

**Option A: Domain-based (Recommended)**
```
Username: alice
Domain: tenant1.voip.local
Password: alice123
Server: localhost:5060
```

**Option B: Prefix-based**
```
Username: 1234*alice
Domain: localhost
Password: alice123
Server: localhost:5060
```

**Verify registration**:
```bash
# Check Kamailio location table
docker exec postgres psql -U kamailio -d kamailio -c \
  "SELECT username, domain, contact FROM location;"
```

### Test 5: Make a Call

**Alice calls Bob**:
```
From: alice@tenant1.voip.local
To: bob@tenant1.voip.local
```

**Or prefix-based**:
```
From: 1234*alice
To: 1234*bob
```

**Verify CDR**:
```bash
# Check Kamailio ACC
docker exec postgres psql -U kamailio -d kamailio -c \
  "SELECT src_user, dst_user, time FROM acc ORDER BY time DESC LIMIT 1;"

# Check FreeSWITCH CDR
docker exec postgres psql -U kamailio -d kamailio -c \
  "SELECT caller_id_number, destination_number, billsec FROM cdr ORDER BY start_stamp DESC LIMIT 1;"
```

### Test 6: Echo Test

Dial `9999` from any registered user:
- Should answer immediately
- Echoes back your voice
- Tests FreeSWITCH dialplan from PostgreSQL

---

## 🔧 Troubleshooting

### Issue 1: XML API Not Responding

**Check logs**:
```bash
docker-compose logs xmlapi
```

**Test database connection**:
```bash
docker exec xmlapi python3 -c "
import psycopg2
conn = psycopg2.connect(host='postgres', database='kamailio', user='kamailio', password='kamailio')
print('Connected!')
"
```

### Issue 2: FreeSWITCH Not Finding Users

**Check xml_curl configuration**:
```bash
docker exec freeswitch fs_cli -x "xml_curl debug_on"
docker exec freeswitch cat /opt/freeswitch/conf/autoload_configs/xml_curl.conf.xml
```

**Test XML Curl manually**:
```bash
# Inside FreeSWITCH container
docker exec freeswitch curl -X POST http://xmlapi:8080/fs/directory \
  -d "user=alice" \
  -d "domain=tenant1.voip.local"
```

### Issue 3: CDR Not Logged

**Check mod_cdr_pgsql**:
```bash
docker exec freeswitch fs_cli -x "module_exists mod_cdr_pgsql"
docker exec freeswitch fs_cli -x "cdr_pgsql status"
```

**Check cdr_pgsql configuration**:
```bash
docker exec freeswitch cat /opt/freeswitch/conf/autoload_configs/cdr_pgsql.conf.xml
```

### Issue 4: Kamailio Authentication Failing

**Enable Kamailio debug**:
```bash
# Edit kamailio.cfg, set debug=3
docker-compose restart kamailio

# Watch logs
docker-compose logs -f kamailio | grep -i auth
```

**Test database query**:
```bash
docker exec postgres psql -U kamailio -d kamailio -c \
  "SELECT username, domain, password FROM subscriber WHERE username='alice';"
```

---

## 🎛️ Management Operations

### Add New Tenant

```sql
INSERT INTO tenants (tenant_code, domain, name, company_name, active)
VALUES ('9999', 'newtenant.voip.local', 'New Tenant', 'New Company', true);
```

### Add New User

```sql
-- For tenant 1234
INSERT INTO subscriber (tenant_id, username, domain, password, ha1, ha1b, display_name)
SELECT
    t.id,
    'newuser',
    t.domain,
    'password123',
    MD5('newuser:' || t.domain || ':password123'),
    MD5('newuser@' || t.domain || ':' || t.domain || ':password123'),
    'New User'
FROM tenants t WHERE t.tenant_code = '1234';
```

### Add Dialplan Rule

```sql
-- Route 411 to directory service
INSERT INTO dialplan (tenant_id, context, destination_number, priority, actions, description)
SELECT
    t.id,
    'default',
    '^411$',
    15,
    '<action application="answer"/><action application="playback" data="/usr/share/freeswitch/sounds/en/us/callie/ivr/8000/ivr-welcome.wav"/>',
    'Directory Service',
    true
FROM tenants t WHERE t.tenant_code = '1234';
```

### View Tenant Usage

```sql
-- Monthly report
SELECT
    t.name,
    COUNT(c.id) as total_calls,
    SUM(c.billsec)/60 as minutes,
    AVG(c.billsec) as avg_duration
FROM cdr c
JOIN tenants t ON c.tenant_id = t.id
WHERE c.start_stamp >= DATE_TRUNC('month', NOW())
GROUP BY t.id, t.name;
```

---

## 📊 Monitoring

### Key Metrics

**Database Connections**:
```bash
docker exec postgres psql -U kamailio -d kamailio -c \
  "SELECT count(*) as connections FROM pg_stat_activity WHERE datname='kamailio';"
```

**Active SIP Registrations**:
```sql
SELECT COUNT(*) as active_registrations
FROM location
WHERE expires > NOW();
```

**Calls Per Tenant (Last Hour)**:
```sql
SELECT
    t.name,
    COUNT(*) as calls
FROM cdr c
JOIN tenants t ON c.tenant_id = t.id
WHERE c.start_stamp >= NOW() - INTERVAL '1 hour'
GROUP BY t.id, t.name;
```

**XML API Performance**:
```bash
# Response time test
curl -w "@-" -o /dev/null -s http://localhost:8080/health <<EOF
    time_total: %{time_total}s
    time_connect: %{time_connect}s
EOF
```

---

## 🔒 Security Considerations

### Database Security
- ✅ Change default PostgreSQL password
- ✅ Use SSL for PostgreSQL connections
- ✅ Implement row-level security for tenants

### API Security
- ⚠️ Add authentication to XML API
- ⚠️ Use HTTPS for XML API (TLS termination)
- ⚠️ Rate limiting per tenant

### SIP Security
- ✅ Enable SIP authentication (already configured)
- ⚠️ Implement fail2ban for brute force protection
- ⚠️ Use encrypted SIP (TLS) for production

---

## 📈 Scaling Strategy

### Horizontal Scaling

**FreeSWITCH** (Per-Tenant):
```yaml
# Add tenant-specific FreeSWITCH
freeswitch-tenant1:
  build: ./freeswitch
  environment:
    TENANT_ID: 1
  ports:
    - "5161:5060/udp"
```

**XML API** (Load Balanced):
```yaml
xmlapi:
  deploy:
    replicas: 3
  environment:
    - POSTGRES_POOL_SIZE=20
```

**PostgreSQL** (Read Replicas):
```yaml
postgres-replica:
  image: postgres:16
  environment:
    - POSTGRES_REPLICATION_MODE=slave
```

---

## ✅ Deployment Checklist

- [ ] Backup existing data
- [ ] Deploy PostgreSQL schema (`init_full_pgsql.sql`)
- [ ] Verify sample data (tenants, users)
- [ ] Build and start XML API service
- [ ] Test XML API endpoints (directory, dialplan, health)
- [ ] Update FreeSWITCH modules configuration
- [ ] Rebuild FreeSWITCH container
- [ ] Start all services
- [ ] Test SIP registration (alice@tenant1.voip.local)
- [ ] Test call flow (Alice → Bob)
- [ ] Verify CDR in PostgreSQL (acc + cdr tables)
- [ ] Test prefix-based routing (1234*alice)
- [ ] Test echo test (dial 9999)
- [ ] Monitor logs for errors
- [ ] Set up monitoring (Prometheus/Grafana)

---

## 🎯 Summary

**What You Get**:
- ✅ Unified PostgreSQL database for all components
- ✅ Multi-tenant support (prefix or domain-based)
- ✅ FreeSWITCH user directory from PostgreSQL
- ✅ Database-driven dialplan
- ✅ Unified CDR (Kamailio + FreeSWITCH)
- ✅ Scalable architecture

**Key Benefits**:
- Single source of truth for user data
- Real-time synchronization
- Easy tenant management
- Centralized billing
- SQL-based reporting

**Next Steps**:
1. Deploy and test basic functionality
2. Implement multi-tenant routing in Kamailio
3. Add tenant admin portal (web UI)
4. Set up monitoring and alerting
5. Implement auto-scaling

---

## 📞 Support

**Logs**:
```bash
# All services
docker-compose logs -f

# Specific service
docker-compose logs -f xmlapi
docker-compose logs -f freeswitch
docker-compose logs -f kamailio
```

**Database Access**:
```bash
docker exec -it postgres psql -U kamailio -d kamailio
```

**FreeSWITCH CLI**:
```bash
docker exec -it freeswitch fs_cli
```

**Kamailio CLI**:
```bash
docker exec -it kamailio kamctl
```
