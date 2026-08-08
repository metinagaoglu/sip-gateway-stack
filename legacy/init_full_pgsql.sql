-- ============================================================================
-- VoIP Stack - Full PostgreSQL Schema
-- Unified database for Kamailio + FreeSWITCH with Multi-Tenancy
-- ============================================================================

-- Version tracking
CREATE TABLE IF NOT EXISTS version (
    table_name VARCHAR(32) NOT NULL,
    table_version INTEGER DEFAULT 0 NOT NULL,
    CONSTRAINT version_t_name_idx PRIMARY KEY (table_name)
);

-- ============================================================================
-- MULTI-TENANT CONFIGURATION
-- ============================================================================

CREATE TABLE IF NOT EXISTS tenants (
    id SERIAL PRIMARY KEY,
    tenant_code VARCHAR(16) UNIQUE NOT NULL,        -- e.g., "1234" (for prefix routing)
    domain VARCHAR(128) UNIQUE NOT NULL,            -- e.g., "tenant1.voip.com"
    name VARCHAR(255) NOT NULL,
    company_name VARCHAR(255),

    -- FreeSWITCH routing
    freeswitch_url VARCHAR(255),                    -- e.g., "sip:fs-tenant1:5060"
    freeswitch_profile VARCHAR(64) DEFAULT 'external', -- SIP profile to use

    -- RTP port range (per-tenant isolation)
    rtp_start_port INTEGER,
    rtp_end_port INTEGER,

    -- Tenant limits
    max_channels INTEGER DEFAULT 100,
    max_users INTEGER DEFAULT 1000,

    -- Status
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX tenants_code_idx ON tenants(tenant_code);
CREATE INDEX tenants_domain_idx ON tenants(domain);
CREATE INDEX tenants_active_idx ON tenants(active);

INSERT INTO version (table_name, table_version) VALUES ('tenants', 1)
ON CONFLICT (table_name) DO UPDATE SET table_version = 1;

-- ============================================================================
-- UNIFIED USER MANAGEMENT (Kamailio + FreeSWITCH)
-- ============================================================================

CREATE TABLE IF NOT EXISTS subscriber (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER REFERENCES tenants(id) ON DELETE CASCADE,

    -- SIP Identity
    username VARCHAR(64) NOT NULL DEFAULT '',
    domain VARCHAR(64) NOT NULL DEFAULT '',

    -- Authentication (Kamailio)
    password VARCHAR(64) NOT NULL DEFAULT '',
    ha1 VARCHAR(64) NOT NULL DEFAULT '',              -- MD5(user:realm:pass)
    ha1b VARCHAR(64) NOT NULL DEFAULT '',             -- MD5(user@domain:realm:pass)

    -- User Details
    email_address VARCHAR(128),
    display_name VARCHAR(128),                        -- Caller ID name for FreeSWITCH

    -- FreeSWITCH Directory Parameters
    dial_string VARCHAR(255),                         -- Custom dial string
    max_calls INTEGER DEFAULT 1,                      -- Concurrent calls limit
    vm_enabled BOOLEAN DEFAULT true,                  -- Voicemail enabled
    vm_password VARCHAR(16),                          -- Voicemail PIN

    -- Call Features
    call_forward VARCHAR(64),                         -- Forward destination
    call_timeout INTEGER DEFAULT 60,                  -- Ring timeout (seconds)
    codec_prefs VARCHAR(255) DEFAULT 'PCMU,PCMA,OPUS', -- Codec preferences

    -- Status
    enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX subscriber_tenant_idx ON subscriber(tenant_id);
CREATE INDEX subscriber_account_idx ON subscriber(username, domain);
CREATE UNIQUE INDEX subscriber_username_domain_idx ON subscriber(username, domain);

INSERT INTO version (table_name, table_version) VALUES ('subscriber', 7)
ON CONFLICT (table_name) DO UPDATE SET table_version = 7;

-- ============================================================================
-- USER LOCATION (Kamailio Registration Tracking)
-- ============================================================================

CREATE TABLE IF NOT EXISTS location (
    id SERIAL PRIMARY KEY,
    ruid VARCHAR(64) NOT NULL DEFAULT '',
    tenant_id INTEGER REFERENCES tenants(id) ON DELETE CASCADE,
    username VARCHAR(64) NOT NULL DEFAULT '',
    domain VARCHAR(64) DEFAULT NULL,
    contact VARCHAR(512) NOT NULL DEFAULT '',
    received VARCHAR(128) DEFAULT NULL,
    path VARCHAR(512) DEFAULT NULL,
    expires TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT '2030-05-28 21:32:15',
    q REAL NOT NULL DEFAULT 1.0,
    callid VARCHAR(255) NOT NULL DEFAULT 'Default-Call-ID',
    cseq INTEGER NOT NULL DEFAULT 1,
    last_modified TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
    flags INTEGER NOT NULL DEFAULT 0,
    cflags INTEGER NOT NULL DEFAULT 0,
    user_agent VARCHAR(255) NOT NULL DEFAULT '',
    socket VARCHAR(64) DEFAULT NULL,
    methods INTEGER DEFAULT NULL,
    instance VARCHAR(255) DEFAULT NULL,
    reg_id INTEGER NOT NULL DEFAULT 0,
    server_id INTEGER NOT NULL DEFAULT 0,
    connection_id INTEGER NOT NULL DEFAULT 0,
    keepalive INTEGER NOT NULL DEFAULT 0,
    partition INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX location_tenant_idx ON location(tenant_id);
CREATE INDEX location_account_contact_idx ON location(username, domain, contact);
CREATE INDEX location_expires_idx ON location(expires);

INSERT INTO version (table_name, table_version) VALUES ('location', 9)
ON CONFLICT (table_name) DO UPDATE SET table_version = 9;

-- ============================================================================
-- FREESWITCH DIALPLAN (PostgreSQL-based routing)
-- ============================================================================

CREATE TABLE IF NOT EXISTS dialplan (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER REFERENCES tenants(id) ON DELETE CASCADE,

    -- Dialplan Matching
    context VARCHAR(64) NOT NULL DEFAULT 'default',
    destination_number VARCHAR(64) NOT NULL,          -- Regex pattern
    priority INTEGER NOT NULL DEFAULT 10,

    -- Condition
    field VARCHAR(64),                                -- e.g., "caller_id_number"
    expression VARCHAR(255),                          -- Regex or value

    -- Actions (XML fragment or JSON)
    actions TEXT NOT NULL,                            -- XML: <action app="..."/>

    -- Metadata
    description VARCHAR(255),
    enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX dialplan_tenant_idx ON dialplan(tenant_id);
CREATE INDEX dialplan_context_idx ON dialplan(context);
CREATE INDEX dialplan_dest_idx ON dialplan(destination_number);
CREATE INDEX dialplan_priority_idx ON dialplan(priority);

INSERT INTO version (table_name, table_version) VALUES ('dialplan', 1)
ON CONFLICT (table_name) DO UPDATE SET table_version = 1;

-- ============================================================================
-- UNIFIED CDR (Kamailio ACC + FreeSWITCH CDR)
-- ============================================================================

-- Kamailio Accounting (Call Attempts)
CREATE TABLE IF NOT EXISTS acc (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER REFERENCES tenants(id) ON DELETE CASCADE,

    method VARCHAR(16) NOT NULL DEFAULT '',
    from_tag VARCHAR(128) NOT NULL DEFAULT '',
    to_tag VARCHAR(128) NOT NULL DEFAULT '',
    callid VARCHAR(255) NOT NULL DEFAULT '',
    sip_code VARCHAR(3) NOT NULL DEFAULT '',
    sip_reason VARCHAR(128) NOT NULL DEFAULT '',
    time TIMESTAMP WITHOUT TIME ZONE NOT NULL,

    src_user VARCHAR(64) NOT NULL DEFAULT '',
    src_domain VARCHAR(128) NOT NULL DEFAULT '',
    src_ip VARCHAR(64) NOT NULL DEFAULT '',
    dst_user VARCHAR(64) NOT NULL DEFAULT '',
    dst_domain VARCHAR(128) NOT NULL DEFAULT '',
    dst_ouser VARCHAR(64) NOT NULL DEFAULT ''
);

CREATE INDEX acc_tenant_idx ON acc(tenant_id);
CREATE INDEX acc_callid_idx ON acc(callid);
CREATE INDEX acc_time_idx ON acc(time);
CREATE INDEX acc_src_user_idx ON acc(src_user);

INSERT INTO version (table_name, table_version) VALUES ('acc', 5)
ON CONFLICT (table_name) DO UPDATE SET table_version = 5;

-- Missed Calls
CREATE TABLE IF NOT EXISTS missed_calls (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER REFERENCES tenants(id) ON DELETE CASCADE,

    method VARCHAR(16) NOT NULL DEFAULT '',
    from_tag VARCHAR(128) NOT NULL DEFAULT '',
    to_tag VARCHAR(128) NOT NULL DEFAULT '',
    callid VARCHAR(255) NOT NULL DEFAULT '',
    sip_code VARCHAR(3) NOT NULL DEFAULT '',
    sip_reason VARCHAR(128) NOT NULL DEFAULT '',
    time TIMESTAMP WITHOUT TIME ZONE NOT NULL,

    src_user VARCHAR(64) NOT NULL DEFAULT '',
    src_domain VARCHAR(128) NOT NULL DEFAULT '',
    src_ip VARCHAR(64) NOT NULL DEFAULT '',
    dst_user VARCHAR(64) NOT NULL DEFAULT '',
    dst_domain VARCHAR(128) NOT NULL DEFAULT '',
    dst_ouser VARCHAR(64) NOT NULL DEFAULT ''
);

CREATE INDEX missed_calls_tenant_idx ON missed_calls(tenant_id);
CREATE INDEX missed_calls_callid_idx ON missed_calls(callid);
CREATE INDEX missed_calls_time_idx ON missed_calls(time);

INSERT INTO version (table_name, table_version) VALUES ('missed_calls', 4)
ON CONFLICT (table_name) DO UPDATE SET table_version = 4;

-- FreeSWITCH CDR (Actual Call Details)
CREATE TABLE IF NOT EXISTS cdr (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER REFERENCES tenants(id) ON DELETE CASCADE,

    uuid UUID NOT NULL,
    caller_id_name VARCHAR(255),
    caller_id_number VARCHAR(255),
    destination_number VARCHAR(255),
    context VARCHAR(255),

    -- Call Timestamps
    start_stamp TIMESTAMP,
    answer_stamp TIMESTAMP,
    end_stamp TIMESTAMP,

    -- Duration
    duration INTEGER,                                 -- Total call duration (seconds)
    billsec INTEGER,                                  -- Billable seconds (after answer)

    -- Call Result
    hangup_cause VARCHAR(255),
    sip_hangup_disposition VARCHAR(64),

    -- Media Info
    read_codec VARCHAR(32),
    write_codec VARCHAR(32),
    remote_media_ip VARCHAR(64),

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX cdr_tenant_idx ON cdr(tenant_id);
CREATE INDEX cdr_uuid_idx ON cdr(uuid);
CREATE INDEX cdr_start_stamp_idx ON cdr(start_stamp);
CREATE INDEX cdr_caller_idx ON cdr(caller_id_number);
CREATE INDEX cdr_destination_idx ON cdr(destination_number);

INSERT INTO version (table_name, table_version) VALUES ('cdr', 1)
ON CONFLICT (table_name) DO UPDATE SET table_version = 1;

-- ============================================================================
-- DISPATCHER (Kamailio → FreeSWITCH Backend Routing)
-- ============================================================================

CREATE TABLE IF NOT EXISTS dispatcher (
    id SERIAL PRIMARY KEY,
    setid INTEGER NOT NULL DEFAULT 0,                -- Group ID
    destination VARCHAR(192) NOT NULL DEFAULT '',    -- sip:freeswitch:5060
    flags INTEGER NOT NULL DEFAULT 0,
    priority INTEGER NOT NULL DEFAULT 0,
    attrs VARCHAR(128) NOT NULL DEFAULT '',
    description VARCHAR(64) NOT NULL DEFAULT ''
);

CREATE INDEX dispatcher_setid_idx ON dispatcher(setid);

INSERT INTO version (table_name, table_version) VALUES ('dispatcher', 4)
ON CONFLICT (table_name) DO UPDATE SET table_version = 4;

-- ============================================================================
-- FREESWITCH XML VIEWS (For xml_curl/xml_pgsql modules)
-- ============================================================================

-- Directory View (User Authentication for FreeSWITCH)
CREATE OR REPLACE VIEW fs_directory AS
SELECT
    s.username AS "user",
    s.domain,
    t.tenant_code,
    s.password,
    s.display_name AS "effective_caller_id_name",
    s.username AS "effective_caller_id_number",
    COALESCE(s.dial_string, 'sofia/internal/${destination_number}@${domain}') AS "dial-string",
    s.max_calls AS "max-calls",
    s.codec_prefs AS "codec-prefs",
    s.call_timeout AS "call-timeout",
    CASE WHEN s.vm_enabled THEN 'true' ELSE 'false' END AS "vm-enabled",
    s.vm_password AS "vm-password",
    s.call_forward AS "forward-destination"
FROM subscriber s
JOIN tenants t ON s.tenant_id = t.id
WHERE s.enabled = true AND t.active = true;

-- Dialplan View (Routing Rules for FreeSWITCH)
CREATE OR REPLACE VIEW fs_dialplan AS
SELECT
    d.id,
    t.tenant_code,
    d.context,
    d.destination_number,
    d.priority,
    d.field,
    d.expression,
    d.actions,
    d.description
FROM dialplan d
JOIN tenants t ON d.tenant_id = t.id
WHERE d.enabled = true AND t.active = true
ORDER BY d.priority, d.id;

-- ============================================================================
-- SAMPLE DATA (Test Tenants and Users)
-- ============================================================================

-- Tenant 1: Test Company
INSERT INTO tenants (tenant_code, domain, name, company_name, freeswitch_url, max_channels, max_users, active)
VALUES
    ('1234', 'tenant1.voip.local', 'Tenant 1', 'Test Company A', 'sip:freeswitch:5060', 100, 500, true),
    ('5678', 'tenant2.voip.local', 'Tenant 2', 'Test Company B', 'sip:freeswitch:5060', 50, 200, true)
ON CONFLICT (tenant_code) DO NOTHING;

-- Test Users for Tenant 1
INSERT INTO subscriber (tenant_id, username, domain, password, ha1, ha1b, display_name, enabled)
SELECT
    t.id,
    'alice',
    'tenant1.voip.local',
    'alice123',
    MD5('alice:tenant1.voip.local:alice123'),
    MD5('alice@tenant1.voip.local:tenant1.voip.local:alice123'),
    'Alice (Tenant 1)',
    true
FROM tenants t WHERE t.tenant_code = '1234'
ON CONFLICT (username, domain) DO NOTHING;

INSERT INTO subscriber (tenant_id, username, domain, password, ha1, ha1b, display_name, enabled)
SELECT
    t.id,
    'bob',
    'tenant1.voip.local',
    'bob123',
    MD5('bob:tenant1.voip.local:bob123'),
    MD5('bob@tenant1.voip.local:tenant1.voip.local:bob123'),
    'Bob (Tenant 1)',
    true
FROM tenants t WHERE t.tenant_code = '1234'
ON CONFLICT (username, domain) DO NOTHING;

-- Test Users for Tenant 2
INSERT INTO subscriber (tenant_id, username, domain, password, ha1, ha1b, display_name, enabled)
SELECT
    t.id,
    'charlie',
    'tenant2.voip.local',
    'charlie123',
    MD5('charlie:tenant2.voip.local:charlie123'),
    MD5('charlie@tenant2.voip.local:tenant2.voip.local:charlie123'),
    'Charlie (Tenant 2)',
    true
FROM tenants t WHERE t.tenant_code = '5678'
ON CONFLICT (username, domain) DO NOTHING;

-- Sample Dialplan Rules
INSERT INTO dialplan (tenant_id, context, destination_number, priority, actions, description, enabled)
SELECT
    t.id,
    'default',
    '^9999$',
    10,
    '<action application="answer"/><action application="echo"/>',
    'Echo Test',
    true
FROM tenants t WHERE t.tenant_code = '1234'
ON CONFLICT DO NOTHING;

INSERT INTO dialplan (tenant_id, context, destination_number, priority, actions, description, enabled)
SELECT
    t.id,
    'default',
    '^(100[0-9])$',
    20,
    '<action application="bridge" data="user/$1@${domain}"/>',
    'Local Extension Range 1000-1009',
    true
FROM tenants t WHERE t.tenant_code = '1234'
ON CONFLICT DO NOTHING;

-- FreeSWITCH Dispatcher Entry
INSERT INTO dispatcher (setid, destination, flags, priority, attrs, description)
VALUES (1, 'sip:freeswitch:5060', 0, 0, '', 'FreeSWITCH Backend')
ON CONFLICT DO NOTHING;

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Function: Get tenant by domain or code
CREATE OR REPLACE FUNCTION get_tenant(identifier VARCHAR)
RETURNS TABLE (
    id INTEGER,
    tenant_code VARCHAR,
    domain VARCHAR,
    name VARCHAR,
    freeswitch_url VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT t.id, t.tenant_code, t.domain, t.name, t.freeswitch_url
    FROM tenants t
    WHERE (t.domain = identifier OR t.tenant_code = identifier)
      AND t.active = true
    LIMIT 1;
END;
$$ LANGUAGE plpgsql;

-- Function: Get user directory XML for FreeSWITCH
CREATE OR REPLACE FUNCTION fs_get_directory_xml(p_user VARCHAR, p_domain VARCHAR)
RETURNS TEXT AS $$
DECLARE
    xml_output TEXT;
BEGIN
    SELECT format(
        '<document type="freeswitch/xml">
          <section name="directory">
            <domain name="%s">
              <user id="%s">
                <params>
                  <param name="password" value="%s"/>
                  <param name="dial-string" value="%s"/>
                </params>
                <variables>
                  <variable name="effective_caller_id_name" value="%s"/>
                  <variable name="effective_caller_id_number" value="%s"/>
                  <variable name="max_calls" value="%s"/>
                </variables>
              </user>
            </domain>
          </section>
        </document>',
        domain,
        "user",
        password,
        "dial-string",
        "effective_caller_id_name",
        "effective_caller_id_number",
        "max-calls"
    )
    INTO xml_output
    FROM fs_directory
    WHERE "user" = p_user AND domain = p_domain;

    RETURN COALESCE(xml_output, '<document type="freeswitch/xml"></document>');
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- COMPLETION MESSAGE
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '============================================================================';
    RAISE NOTICE 'VoIP Stack - Full PostgreSQL Schema Created Successfully!';
    RAISE NOTICE '============================================================================';
    RAISE NOTICE '';
    RAISE NOTICE 'Multi-Tenant Configuration:';
    RAISE NOTICE '  - tenants (2 test tenants created)';
    RAISE NOTICE '  - Tenant 1: code=1234, domain=tenant1.voip.local';
    RAISE NOTICE '  - Tenant 2: code=5678, domain=tenant2.voip.local';
    RAISE NOTICE '';
    RAISE NOTICE 'Unified User Management:';
    RAISE NOTICE '  - subscriber (Kamailio + FreeSWITCH users)';
    RAISE NOTICE '  - Test Users: alice, bob (tenant1), charlie (tenant2)';
    RAISE NOTICE '';
    RAISE NOTICE 'FreeSWITCH Integration:';
    RAISE NOTICE '  - fs_directory (user authentication view)';
    RAISE NOTICE '  - fs_dialplan (routing rules view)';
    RAISE NOTICE '  - dialplan (database-driven routing)';
    RAISE NOTICE '';
    RAISE NOTICE 'CDR & Accounting:';
    RAISE NOTICE '  - acc (Kamailio call accounting)';
    RAISE NOTICE '  - cdr (FreeSWITCH call detail records)';
    RAISE NOTICE '  - missed_calls (unanswered calls)';
    RAISE NOTICE '';
    RAISE NOTICE 'Next Steps:';
    RAISE NOTICE '  1. Configure FreeSWITCH mod_xml_curl or mod_xml_pgsql';
    RAISE NOTICE '  2. Enable mod_cdr_pgsql in FreeSWITCH';
    RAISE NOTICE '  3. Update Kamailio config for multi-tenancy';
    RAISE NOTICE '  4. Test with: alice@tenant1.voip.local or 1234*alice';
    RAISE NOTICE '============================================================================';
END $$;
