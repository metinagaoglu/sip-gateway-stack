-- max_calls.lua
--
-- Cagiran kullanicinin subscriber.max_calls degerini PostgreSQL'den okur ve
-- kanal degiskeni `user_max_calls` olarak yazar. Dialplan bu degeri `limit`
-- uygulamasina verir.
--
-- NEDEN LUA: mod_pgsql bir veritabani ARAYUZ modulu, dialplan uygulamasi
-- saglamaz. Eski dialplan'daki `<action application="pgsql" .../>` bu yuzden
-- hic calismadi (Invalid Application). FreeSWITCH'ten ad-hoc SQL calistirmanin
-- desteklenen yolu `freeswitch.Dbh` nesnesidir.
--
-- KAPSAM: dogrudan SQL YALNIZCA bu senaryoda kullanilir. Dialplan'a SQL
-- yaymak bakimi zorlastirir; geri kalan ihtiyaclari xml_curl karsiliyor.
--
-- Kullanim (dialplan):
--   <action application="lua" data="max_calls.lua ${sip_from_user} ${sip_from_host}"/>
-- Kullanim (CLI, dogrulama scripti bunu kullanir):
--   lua max_calls.lua alice tenant1.voip.local

local DEFAULT_MAX = 1

local user   = argv[1]
local domain = argv[2]

local function log(level, msg)
    freeswitch.consoleLog(level, "[max_calls] " .. msg .. "\n")
end

-- Deger HER YOLDA yazilir: hata durumunda bile degisken bos kalmamali,
-- yoksa dialplan'daki `limit ... ${user_max_calls}` bos argumanla cagrilir.
local function publish(max_calls, why)
    if session then
        session:setVariable("user_max_calls", tostring(max_calls))
    end
    -- Tek satirlik, ayristirilabilir cikti. Dogrulama scripti `max_calls=<n>`
    -- desenine ANKORLU arama yapar; serbest metne guvenilmez.
    local line = string.format("%s@%s -> max_calls=%d (%s)",
        tostring(user), tostring(domain), max_calls, why)
    log("info", line)
    -- API modunda (`fs_cli -x "lua max_calls.lua ..."`) `stream` global'i
    -- vardir. Buraya yazilmazsa fs_cli `-ERR no reply` doner ve script
    -- CALISMAMIS gibi gorunur — oysa consoleLog satiri log DOSYASINA
    -- yazilmistir (mod_logfile), `docker compose logs` ciktisina degil.
    -- Bu ayrim teshis sirasinda gercekten yanilttigi icin not edildi.
    if stream then
        stream:write("[max_calls] " .. line .. "\n")
    end
end

if not user or user == "" or not domain or domain == "" then
    publish(DEFAULT_MAX, "user/domain eksik")
    return
end

local dsn = string.format(
    "pgsql://host=%s port=%s dbname=%s user=%s password=%s",
    os.getenv("POSTGRES_HOST") or "postgres",
    os.getenv("POSTGRES_PORT") or "5432",
    os.getenv("POSTGRES_DB")   or "kamailio",
    os.getenv("POSTGRES_USER") or "kamailio",
    os.getenv("POSTGRES_PASSWORD") or ""
)

local dbh = freeswitch.Dbh(dsn)
if not dbh or not dbh:connected() then
    -- Veritabani erisilemezse cagri KESILMEZ, en kisitlayici degere duser.
    publish(DEFAULT_MAX, "PostgreSQL baglantisi kurulamadi")
    return
end

-- Lua Dbh API'sinde parametreli sorgu YOK, degerleri elle escape ediyoruz.
-- Tek tirnak ikilenir (SQL standardi). Kullanici adi Kamailio tarafindan
-- digest ile dogrulanmis olsa da bu katmanda guvenmiyoruz.
local safe_user   = tostring(user):gsub("'", "''")
local safe_domain = tostring(domain):gsub("'", "''")

local max_calls = nil
local sql = string.format(
    "SELECT max_calls FROM subscriber " ..
    "WHERE username = '%s' AND domain = '%s' AND enabled = true LIMIT 1",
    safe_user, safe_domain
)

dbh:query(sql, function(row)
    max_calls = tonumber(row.max_calls)
end)
dbh:release()

if max_calls == nil then
    publish(DEFAULT_MAX, "kullanici bulunamadi")
else
    publish(max_calls, "veritabanindan")
end
