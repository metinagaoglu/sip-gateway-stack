INSERT INTO tenants (tenant_code, domain, name, company_name, freeswitch_url, max_channels, max_users, active)
VALUES ('1234', 'tenant1.voip.local', 'Tenant 1', 'Test Company A', 'sip:freeswitch:5060', 100, 500, true)
ON CONFLICT (tenant_code) DO NOTHING;

INSERT INTO subscriber (tenant_id, username, domain, password, ha1, ha1b, display_name, max_calls, enabled)
SELECT t.id, v.username, t.domain, v.password,
       md5(v.username || ':' || t.domain || ':' || v.password),
       md5(v.username || '@' || t.domain || ':' || t.domain || ':' || v.password),
       v.display_name, 2, true
FROM tenants t
CROSS JOIN (VALUES
    ('alice', 'alice123', 'Alice'),
    ('bob',   'bob123',   'Bob')
) AS v(username, password, display_name)
WHERE t.tenant_code = '1234'
ON CONFLICT DO NOTHING;

-- flags=16 (bit 4, "skip DNS A/AAAA resolve at startup"): Task 4 zamaninda
-- 'freeswitch' servisi henuz yok (Task 5'te eklenecek), bu yuzden hostname
-- hic cozulmuyor. flags=0 ile Kamailio'nun dispatcher modulu ds_load_db()
-- sirasinda pack_dest() cozumlemesi basarisiz oldugu icin hedefi kume 1'e
-- HIC EKLEMIYOR (crash degil, ama "kamcmd dispatcher.list" bos donuyor —
-- bkz. task-4-report.md). flags=16 bu erken cozumlemeyi atlar, hedef listeye
-- girer (Inactive/henuz probe edilmemis olarak), Task 5'te freeswitch
-- ayaga kalkinca normal calisir.
INSERT INTO dispatcher (setid, destination, flags, priority, description)
SELECT 1, 'sip:freeswitch:5060', 16, 0, 'FreeSWITCH node 1'
WHERE NOT EXISTS (
    SELECT 1 FROM dispatcher WHERE setid = 1 AND destination = 'sip:freeswitch:5060'
);
