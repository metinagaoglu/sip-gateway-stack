-- Kamailio PostgreSQL Database Schema
-- Version table (Kamailio tüm tablolar için versiyon kontrolü yapar)

CREATE TABLE version (
    table_name VARCHAR(32) NOT NULL,
    table_version INTEGER DEFAULT 0 NOT NULL,
    CONSTRAINT version_t_name_idx PRIMARY KEY (table_name)
);

-- Subscriber table (Kullanıcı kimlik bilgileri)
CREATE TABLE subscriber (
    id SERIAL PRIMARY KEY,
    username VARCHAR(64) NOT NULL DEFAULT '',
    domain VARCHAR(64) NOT NULL DEFAULT '',
    password VARCHAR(64) NOT NULL DEFAULT '',
    email_address VARCHAR(64) NOT NULL DEFAULT '',
    ha1 VARCHAR(64) NOT NULL DEFAULT '',
    ha1b VARCHAR(64) NOT NULL DEFAULT '',
    rpid VARCHAR(64) DEFAULT NULL
);

CREATE INDEX subscriber_account_idx ON subscriber (username, domain);
CREATE UNIQUE INDEX subscriber_username_idx ON subscriber (username, domain);

INSERT INTO version (table_name, table_version) VALUES ('subscriber', 7);

-- Location table (Kullanıcı kayıt bilgileri - REGISTER)
CREATE TABLE location (
    id SERIAL PRIMARY KEY,
    ruid VARCHAR(64) NOT NULL DEFAULT '',
    username VARCHAR(64) NOT NULL DEFAULT '',
    domain VARCHAR(64) DEFAULT NULL,
    contact VARCHAR(512) NOT NULL DEFAULT '',
    received VARCHAR(128) DEFAULT NULL,
    path VARCHAR(512) DEFAULT NULL,
    expires TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT '2030-05-28 21:32:15',
    q REAL NOT NULL DEFAULT 1.0,
    callid VARCHAR(255) NOT NULL DEFAULT 'Default-Call-ID',
    cseq INTEGER NOT NULL DEFAULT 1,
    last_modified TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT '2000-01-01 00:00:01',
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

CREATE INDEX location_account_contact_idx ON location (username, domain, contact);
CREATE INDEX location_expires_idx ON location (expires);
CREATE INDEX location_connection_idx ON location (server_id, connection_id);

INSERT INTO version (table_name, table_version) VALUES ('location', 9);

-- Dispatcher table (FreeSWITCH gibi backend sunucular için)
CREATE TABLE dispatcher (
    id SERIAL PRIMARY KEY,
    setid INTEGER NOT NULL DEFAULT 0,
    destination VARCHAR(192) NOT NULL DEFAULT '',
    flags INTEGER NOT NULL DEFAULT 0,
    priority INTEGER NOT NULL DEFAULT 0,
    attrs VARCHAR(128) NOT NULL DEFAULT '',
    description VARCHAR(64) NOT NULL DEFAULT ''
);

CREATE INDEX dispatcher_setid_idx ON dispatcher (setid);

INSERT INTO version (table_name, table_version) VALUES ('dispatcher', 4);

-- Test kullanıcısı ekleyelim (şifre: test123)
-- ha1 = MD5(username:realm:password) = MD5(test:kamailio:test123)
INSERT INTO subscriber (username, domain, password, ha1, ha1b) 
VALUES (
    'test',
    'kamailio',
    'test123',
    MD5('test:kamailio:test123'),
    MD5('test@kamailio:kamailio:test123')
);

-- FreeSWITCH dispatcher kaydı
INSERT INTO dispatcher (setid, destination, flags, priority, attrs, description)
VALUES (1, 'sip:freeswitch:5060', 0, 0, '', 'FreeSWITCH Backend');

-- Kamailio Accounting (CDR) Tables
CREATE TABLE IF NOT EXISTS acc (
    id SERIAL PRIMARY KEY,
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

CREATE INDEX IF NOT EXISTS acc_callid_idx ON acc(callid);
CREATE INDEX IF NOT EXISTS acc_time_idx ON acc(time);
CREATE INDEX IF NOT EXISTS acc_src_user_idx ON acc(src_user);
CREATE INDEX IF NOT EXISTS acc_dst_user_idx ON acc(dst_user);

INSERT INTO version (table_name, table_version) VALUES ('acc', 5)
ON CONFLICT (table_name) DO UPDATE SET table_version = 5;

CREATE TABLE IF NOT EXISTS missed_calls (
    id SERIAL PRIMARY KEY,
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

CREATE INDEX IF NOT EXISTS missed_calls_callid_idx ON missed_calls(callid);
CREATE INDEX IF NOT EXISTS missed_calls_time_idx ON missed_calls(time);

INSERT INTO version (table_name, table_version) VALUES ('missed_calls', 4)
ON CONFLICT (table_name) DO UPDATE SET table_version = 4;

-- FreeSWITCH CDR Table
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

CREATE INDEX IF NOT EXISTS cdr_uuid_idx ON cdr(uuid);
CREATE INDEX IF NOT EXISTS cdr_start_stamp_idx ON cdr(start_stamp);
CREATE INDEX IF NOT EXISTS cdr_caller_idx ON cdr(caller_id_number);
CREATE INDEX IF NOT EXISTS cdr_destination_idx ON cdr(destination_number);

INSERT INTO version (table_name, table_version) VALUES ('cdr', 1)
ON CONFLICT (table_name) DO UPDATE SET table_version = 1;

-- Veritabanı hazır mesajı
DO $$
BEGIN
    RAISE NOTICE '==============================================';
    RAISE NOTICE 'VoIP Stack Database Schema Created!';
    RAISE NOTICE '==============================================';
    RAISE NOTICE '';
    RAISE NOTICE 'Kamailio Tables:';
    RAISE NOTICE '  - subscriber (test user created)';
    RAISE NOTICE '  - location (registration tracking)';
    RAISE NOTICE '  - dispatcher (FreeSWITCH backend)';
    RAISE NOTICE '  - acc (call accounting/CDR)';
    RAISE NOTICE '  - missed_calls (unanswered calls)';
    RAISE NOTICE '';
    RAISE NOTICE 'FreeSWITCH Tables:';
    RAISE NOTICE '  - cdr (call detail records)';
    RAISE NOTICE '';
    RAISE NOTICE 'Test User Credentials:';
    RAISE NOTICE '  Username: test';
    RAISE NOTICE '  Domain: kamailio';
    RAISE NOTICE '  Password: test123';
    RAISE NOTICE '==============================================';
END $$;