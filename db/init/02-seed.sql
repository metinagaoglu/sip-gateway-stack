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

-- flags = 8 (DS_PROBING_DST) ZORUNLU, 0 DEGIL.
-- Hedef bir hostname ('freeswitch') ve Docker DNS kaydi ancak o kapsayici
-- ayaga kalkinca olusur. Kamailio FreeSWITCH'ten ONCE baslarsa (compose'da
-- kamailio'nun freeswitch'e depends_on'u YOK ve olamaz -- karsilikli
-- bagimlilik olurdu) dispatcher yuklemesi DNS'i cozemez ve flags=0 iken
-- hedefi TAMAMEN ATLAR:
--     ERROR  pack_dest(): could not resolve freeswitch (missing no-probing flag?!?)
--     WARNING ds_load_db(): unable to add destination ... -- skipping
--     ERROR  ds_manage_routes(): no destination sets
-- Sonuc: dispatcher listesi BOS kalir ve BUTUN cagrilar
-- "503 No Media Server Available" alir -- Kamailio elle yeniden baslatilana
-- kadar KALICI olarak. Yeniden baslatma sirasina bagli, sessiz bir kirilma.
-- flags=8 ile hedef probing modunda eklenir; DNS sonra cozulur ve OPTIONS
-- ping'i hedefi aktif hale getirir.
-- Regresyon: scripts/verify-94-startup-order.sh
INSERT INTO dispatcher (setid, destination, flags, priority, description)
SELECT 1, 'sip:freeswitch:5060', 8, 0, 'FreeSWITCH node 1'
WHERE NOT EXISTS (
    SELECT 1 FROM dispatcher WHERE setid = 1 AND destination = 'sip:freeswitch:5060'
);

-- Mevcut kurulumlar icin: flags=0 ile olusmus satiri duzelt.
UPDATE dispatcher SET flags = 8
WHERE destination = 'sip:freeswitch:5060' AND flags = 0;
