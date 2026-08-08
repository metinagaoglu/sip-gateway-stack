# PostgreSQL-Centric VoIP Architecture Implementation Guide

## 🎯 Architecture Overview

```
┌───────────────────────────────────────────────────────┐
│              PostgreSQL Database                      │
│           (Single Source of Truth)                    │
├───────────────────────────────────────────────────────┤
│ • tenants          → Multi-tenant configuration       │
│ • subscriber       → Unified user database            │
│ • location         → SIP registrations (Kamailio)     │
│ • dialplan         → FreeSWITCH routing rules         │
│ • acc + cdr        → Unified call records             │
│ • fs_directory     → FreeSWITCH user auth view        │
│ • fs_dialplan      → FreeSWITCH dialplan view         │
└───────────────────────────────────────────────────────┘
            ↓                              ↓
    ┌───────────────┐              ┌──────────────┐
    │   Kamailio    │←────────────→│  FreeSWITCH  │
    │   (Proxy)     │   SIP/RTP    │   (Media)    │
    └───────────────┘              └──────────────┘
         ↓                              ↓
    PostgreSQL                     PostgreSQL
    (subscriber)                   (directory/dialplan)
```

## ✅ What's Implemented

### Database Schema (`init_full_pgsql.sql`)
- ✅ Multi-tenant configuration (`tenants` table)
- ✅ Unified user management (`subscriber` table)
- ✅ Location tracking (`location` table)
- ✅ PostgreSQL-based dialplan (`dialplan` table)
- ✅ Unified CDR (`acc`, `cdr`, `missed_calls`)
- ✅ FreeSWITCH views (`fs_directory`, `fs_dialplan`)
- ✅ Helper functions for XML generation
- ✅ Sample data (2 tenants, 3 test users)

### Kamailio Integration
- ✅ PostgreSQL connection configured
- ✅ User authentication from `subscriber` table
- ✅ CDR logging to `acc` table
- ⚠️ Multi-tenant routing (needs implementation)

### FreeSWITCH Integration
- ✅ `mod_pgsql` compiled and loaded
- ✅ `mod_cdr_pgsql` compiled (not loaded yet)
- ✅ PostgreSQL connection configured
- ⚠️ User directory (needs xml_curl or xml_pgsql)
- ⚠️ Dialplan from PostgreSQL (needs implementation)

---

## 🔧 Implementation Steps

### Step 1: Deploy New Database Schema

**Replace** `init.sql` with `init_full_pgsql.sql`:

```bash
# Stop containers
docker-compose down

# Backup existing data (optional)
docker exec voip_stack-postgres-1 pg_dump -U kamailio kamailio > backup.sql

# Clear PostgreSQL volume (fresh start)
docker volume rm voip_stack_pg_data

# Update docker-compose.yml
# Change: ./init.sql → ./init_full_pgsql.sql
```

**docker-compose.yml** change:
```yaml
postgres:
  volumes:
    - ./init_full_pgsql.sql:/docker-entrypoint-initdb.d/init.sql  # ← Changed
```

```bash
# Start with new schema
docker-compose up -d postgres
docker-compose logs -f postgres  # Verify schema creation
```

---

### Step 2: FreeSWITCH PostgreSQL Integration

#### Option A: XML Curl (Recommended) ⭐

**Architecture**:
```
FreeSWITCH → HTTP Request → XML API Service → PostgreSQL
```

**Pros**:
- ✅ Flexible (Python/Node.js service)
- ✅ Easy debugging
- ✅ Custom logic support
- ✅ Caching layer possible

**Implementation**:

1. **Create XML API Service** (`xmlapi/app.py`):

```python
from flask import Flask, request
import psycopg2
from psycopg2.extras import RealDictCursor

app = Flask(__name__)

# PostgreSQL connection
def get_db():
    return psycopg2.connect(
        host='postgres',
        database='kamailio',
        user='kamailio',
        password='kamailio',
        cursor_factory=RealDictCursor
    )

@app.route('/fs/directory', methods=['GET', 'POST'])
def directory():
    user = request.values.get('user')
    domain = request.values.get('domain')

    if not user or not domain:
        return '<document type="freeswitch/xml"></document>', 200

    conn = get_db()
    cur = conn.cursor()

    cur.execute("""
        SELECT * FROM fs_directory
        WHERE "user" = %s AND domain = %s
    """, (user, domain))

    user_data = cur.fetchone()
    cur.close()
    conn.close()

    if not user_data:
        return '<document type="freeswitch/xml"></document>', 200

    xml = f"""<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document type="freeswitch/xml">
  <section name="directory">
    <domain name="{domain}">
      <user id="{user}">
        <params>
          <param name="password" value="{user_data['password']}"/>
          <param name="dial-string" value="{user_data['dial-string']}"/>
        </params>
        <variables>
          <variable name="effective_caller_id_name" value="{user_data['effective_caller_id_name']}"/>
          <variable name="effective_caller_id_number" value="{user_data['effective_caller_id_number']}"/>
          <variable name="max_calls" value="{user_data['max-calls']}"/>
          <variable name="tenant_code" value="{user_data['tenant_code']}"/>
        </variables>
      </user>
    </domain>
  </section>
</document>"""

    return xml, 200, {'Content-Type': 'application/xml'}

@app.route('/fs/dialplan', methods=['GET', 'POST'])
def dialplan():
    context = request.values.get('Hunt-Context', 'default')
    destination = request.values.get('Hunt-Destination-Number', '')

    conn = get_db()
    cur = conn.cursor()

    cur.execute("""
        SELECT * FROM fs_dialplan
        WHERE context = %s
        AND %s ~ destination_number
        ORDER BY priority
        LIMIT 1
    """, (context, destination))

    rule = cur.fetchone()
    cur.close()
    conn.close()

    if not rule:
        return '<document type="freeswitch/xml"></document>', 200

    xml = f"""<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document type="freeswitch/xml">
  <section name="dialplan">
    <context name="{context}">
      <extension name="db-rule-{rule['id']}">
        <condition field="destination_number" expression="{rule['destination_number']}">
          {rule['actions']}
        </condition>
      </extension>
    </context>
  </section>
</document>"""

    return xml, 200, {'Content-Type': 'application/xml'}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)
```

2. **Dockerfile** (`xmlapi/Dockerfile`):

```dockerfile
FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir flask psycopg2-binary gunicorn

COPY app.py .

CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:8080", "app:app"]
```

3. **docker-compose.yml** addition:

```yaml
services:
  xmlapi:
    build: ./xmlapi
    container_name: xmlapi
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_DB: kamailio
      POSTGRES_USER: kamailio
      POSTGRES_PASSWORD: kamailio
    depends_on:
      - postgres
    networks:
      - voip_net
```

4. **Update FreeSWITCH modules.conf.xml**:

```xml
<!-- Add xml_curl module -->
<load module="mod_xml_curl"/>
```

5. **Create xml_curl.conf.xml** (already done above)

---

#### Option B: Direct PostgreSQL (`mod_xml_pgsql`)

**Note**: `mod_xml_pgsql` is NOT in standard FreeSWITCH. Use `xml_curl` instead.

---

### Step 3: Enable FreeSWITCH CDR to PostgreSQL

**Update** `freeswitch/conf/autoload_configs/modules.conf.xml`:

```xml
<!-- Add CDR module -->
<load module="mod_cdr_pgsql"/>
```

**Update** `freeswitch/conf/autoload_configs/cdr_pgsql.conf.xml`:

```xml
<configuration name="cdr_pgsql.conf" description="PostgreSQL CDR">
  <settings>
    <param name="db-name" value="kamailio"/>
    <param name="db-host" value="postgres"/>
    <param name="db-port" value="5432"/>
    <param name="db-user" value="kamailio"/>
    <param name="db-pass" value="kamailio"/>

    <param name="log-leg" value="both"/>

    <!-- Map FreeSWITCH variables to cdr table columns -->
    <param name="tenant_id" value="${tenant_id}"/>
    <param name="uuid" value="${uuid}"/>
    <param name="caller_id_name" value="${caller_id_name}"/>
    <param name="caller_id_number" value="${caller_id_number}"/>
    <param name="destination_number" value="${destination_number}"/>
    <param name="context" value="${context}"/>
    <param name="start_stamp" value="${start_stamp}"/>
    <param name="answer_stamp" value="${answer_stamp}"/>
    <param name="end_stamp" value="${end_stamp}"/>
    <param name="duration" value="${duration}"/>
    <param name="billsec" value="${billsec}"/>
    <param name="hangup_cause" value="${hangup_cause}"/>
    <param name="read_codec" value="${read_codec}"/>
    <param name="write_codec" value="${write_codec}"/>
  </settings>
</configuration>
```

---

### Step 4: Update Kamailio for Multi-Tenancy

**Key Changes** in `kamailio/kamailio.cfg`:

```c
# Enable domain-aware mode
modparam("auth_db", "use_domain", 1)
modparam("usrloc", "use_domain", 1)

# Add tenant routing (see earlier multi-tenant section)
route[TENANT_IDENTIFY] {
    # Prefix-based: 1234*100
    if ($rU =~ "^([0-9]+)\*(.+)$") {
        $var(tenant_code) = $(rU{re.subst,/^([0-9]+)\*.*/\1/});
        $var(extension) = $(rU{re.subst,/^[0-9]+\*(.*)/\1/});
        $rU = $var(extension);

        # Lookup tenant
        sql_query("db", "SELECT id FROM tenants WHERE tenant_code='$var(tenant_code)'", "ra");
        $var(tenant_id) = $dbr(ra=>[0,0]);
        sql_result_free("ra");
    } else {
        # Domain-based: alice@tenant1.voip.local
        $var(tenant_domain) = $rd;
    }
}
```

---

## 🧪 Testing Guide

### Test 1: Database Verification

```bash
# Access PostgreSQL
docker exec -it voip_stack-postgres-1 psql -U kamailio -d kamailio

-- Check tenants
SELECT * FROM tenants;

-- Check users
SELECT id, username, domain, tenant_id, enabled FROM subscriber;

-- Check FreeSWITCH directory view
SELECT "user", domain, tenant_code, password FROM fs_directory;

-- Check dialplan rules
SELECT * FROM fs_dialplan;
```

### Test 2: FreeSWITCH User Lookup

```bash
# Test XML API (if using xml_curl)
curl -X POST http://localhost:8080/fs/directory \
  -d "user=alice" \
  -d "domain=tenant1.voip.local"

# Expected: XML with user authentication data
```

### Test 3: SIP Registration

```bash
# Register alice@tenant1.voip.local
# SIP Client config:
#   Username: alice
#   Domain: tenant1.voip.local
#   Password: alice123
#   Server: kamailio:5060

# Or prefix-based:
#   Username: 1234*alice
#   Domain: kamailio
#   Password: alice123
```

### Test 4: Call Flow

```bash
# Alice calls Bob (same tenant)
INVITE sip:bob@tenant1.voip.local

# Or prefix-based
INVITE sip:1234*bob@kamailio

# Check CDR
SELECT * FROM cdr ORDER BY start_stamp DESC LIMIT 1;
SELECT * FROM acc ORDER BY time DESC LIMIT 1;
```

---

## 📊 Benefits of PostgreSQL-Centric Architecture

### Unified Data Management
- ✅ Single source of truth for all users
- ✅ Real-time synchronization between Kamailio and FreeSWITCH
- ✅ No data duplication

### Multi-Tenancy Support
- ✅ Tenant isolation at database level
- ✅ Per-tenant FreeSWITCH instances
- ✅ Flexible routing (prefix or domain-based)

### Operational Advantages
- ✅ Centralized user provisioning
- ✅ Unified billing and CDR
- ✅ Easy tenant management
- ✅ SQL-based reporting

### Scalability
- ✅ Horizontal scaling of FreeSWITCH
- ✅ PostgreSQL replication support
- ✅ Tenant-specific resource allocation

---

## 🚀 Deployment Checklist

- [ ] Step 1: Deploy new PostgreSQL schema (`init_full_pgsql.sql`)
- [ ] Step 2: Verify sample data (tenants, users, dialplan)
- [ ] Step 3: Deploy XML API service (Flask app)
- [ ] Step 4: Update FreeSWITCH modules (xml_curl, cdr_pgsql)
- [ ] Step 5: Update Kamailio config (multi-tenancy)
- [ ] Step 6: Test SIP registration (alice@tenant1.voip.local)
- [ ] Step 7: Test call flow (Alice → Bob)
- [ ] Step 8: Verify CDR in PostgreSQL
- [ ] Step 9: Test prefix-based routing (1234*alice)
- [ ] Step 10: Production deployment with monitoring

---

## 📝 Next Steps

1. **Immediate**: Deploy XML API service for FreeSWITCH directory
2. **Short-term**: Implement multi-tenant routing in Kamailio
3. **Medium-term**: Add tenant admin portal (web UI)
4. **Long-term**: Implement auto-scaling and monitoring

---

## ⚠️ Known Limitations

1. **XML Curl Dependency**: FreeSWITCH requires HTTP service for directory
   - Alternative: Use `mod_lua` with PostgreSQL queries

2. **CDR Timing**: Small delay between Kamailio acc and FreeSWITCH cdr
   - Solution: Event Socket CDR handler for real-time sync

3. **Caching**: XML curl queries hit database on every lookup
   - Solution: Redis cache in XML API service

---

## 🔗 Reference Queries

### User Management

```sql
-- Add new user
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

-- Update user password
UPDATE subscriber
SET password = 'newpass',
    ha1 = MD5(username || ':' || domain || ':newpass'),
    ha1b = MD5(username || '@' || domain || ':' || domain || ':newpass')
WHERE username = 'alice' AND domain = 'tenant1.voip.local';

-- Disable user
UPDATE subscriber SET enabled = false WHERE username = 'alice';
```

### Dialplan Management

```sql
-- Add dialplan rule (route to external gateway)
INSERT INTO dialplan (tenant_id, context, destination_number, priority, actions, description)
SELECT
    t.id,
    'default',
    '^(\\+?[1-9]\\d{9,14})$',  -- International format
    30,
    '<action application="bridge" data="sofia/external/$1@gateway.pstn.provider.com"/>',
    'PSTN Gateway',
    true
FROM tenants t WHERE t.tenant_code = '1234';
```

### Tenant Billing Report

```sql
-- Monthly usage per tenant
SELECT
    t.name,
    t.tenant_code,
    COUNT(c.id) as total_calls,
    SUM(c.billsec)/60 as total_minutes,
    AVG(c.billsec) as avg_call_duration
FROM cdr c
JOIN tenants t ON c.tenant_id = t.id
WHERE c.start_stamp >= DATE_TRUNC('month', NOW())
GROUP BY t.id, t.name, t.tenant_code
ORDER BY total_calls DESC;
```

---

## 🎯 Summary

**Architecture**: PostgreSQL-centric with unified data model
**Multi-Tenancy**: Domain-based or prefix-based routing
**Integration**: XML Curl API for FreeSWITCH directory
**CDR**: Unified logging (Kamailio acc + FreeSWITCH cdr)
**Status**: Schema ready, needs XML API deployment

**Ready for**: Test deployment and validation
