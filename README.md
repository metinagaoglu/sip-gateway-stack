# VoIP Stack — Kamailio + FreeSWITCH + PostgreSQL

A multi-tenant SIP platform running Kamailio (SIP proxy/registrar), FreeSWITCH
(media server) and PostgreSQL in a single Docker Compose stack. Everything is
driven by `.env`; no environment-specific values are hardcoded.

## Architecture

```
  softphone ──UDP 5060──> Kamailio ──dispatcher──> FreeSWITCH
                             │                        │
                             │  (registration/auth)   │  (media, dialplan)
                             ▼                        ▼
                        PostgreSQL: kamailio      PostgreSQL: freeswitch
                        subscriber, location,     channels, calls,
                        dispatcher, cdr           registrations, limit_data
```

**Division of labour:** Kamailio owns registration and digest authentication,
then hands the call to FreeSWITCH via the dispatcher. FreeSWITCH anchors media
as a B2BUA. Because FreeSWITCH knows nothing about registrations, user-to-user
calls are sent back to Kamailio through `outbound-proxy`, and Kamailio resolves
the target with `lookup("location")`. FreeSWITCH runs with `auth-calls=false` —
authentication happens in exactly one place (Kamailio) and access to FreeSWITCH
is restricted by ACL instead.

**The two databases are deliberate:** `kamailio` holds subscriber, routing and
reporting data; `freeswitch` holds FreeSWITCH's own operational state.

## Quick start

```bash
cp .env.example .env
# set EXTERNAL_IP to this machine's LAN address, change the passwords
docker compose up -d --build
./scripts/verify-all.sh
```

`verify-all.sh` runs every verification script and finishes with a stack
summary (container health + FreeSWITCH RestartCount). Expected: `FAIL=0`.

## Softphone settings (Zoiper etc.)

| Field | Value |
|---|---|
| Domain / SIP server | `tenant1.voip.local` |
| Username | `alice` (or `bob`) |
| Password | `alice123` (`bob123`) |
| Transport | **UDP** |

Kamailio listens on UDP only; picking TCP yields "no transport left to try".
If `tenant1.voip.local` does not resolve, add `<EXTERNAL_IP> tenant1.voip.local`
to `/etc/hosts` or set the outbound proxy to `<EXTERNAL_IP>:5060`.

**Do not replace the domain with an IP.** `subscriber.ha1` is computed as
`md5(user:domain:password)`; changing the realm produces an endless 401 loop.

### Test numbers

| Number | Behaviour |
|---|---|
| `9999` | echo (you hear yourself back) |
| `9998` | tone test |
| `bob` / `alice` | user-to-user call |
| 10–15 digits, `+E.164`, `00…` | SIP trunk (when enabled) |

## Adding users and tenants

```bash
./tools/add-user.sh <user> <password> <domain>
```

The script computes `ha1` with the correct realm. If you insert rows by hand:
`ha1 = md5(user:domain:password)`.

Tenancy relies on `use_domain=1`: `alice@tenant1` and `alice@tenant2` are
**different** users, and one tenant's password will not unlock the other's
account. This behaviour is verified by `scripts/verify-91-tenant-isolation.sh`.

## SIP trunk

Provider-agnostic; a single template covers both modes. In `.env`:

```
TRUNK_ENABLED=true
TRUNK_NAME=<gateway name>
TRUNK_HOST=<provider host>
TRUNK_USER=<user>
TRUNK_PASS=<password>
TRUNK_REGISTER=true     # credential mode; false for IP authorization
```

```bash
docker compose up -d --build freeswitch
./scripts/verify-12-trunk-out.sh
```

While `TRUNK_ENABLED=false` no gateway is created at all (the entrypoint
deletes the rendered `trunk.xml`), so FreeSWITCH never retries REGISTER against
an empty address. Inbound trunk calls and TLS/SRTP are **out of scope for now**.

## Known pitfalls

This section records failures that actually happened. Read it before changing
configuration.

**If a config change seems to have no effect, you probably need `--build`.**
`kamailio.cfg` and `freeswitch/entrypoint.sh` are COPY'd into the image, not
bind-mounted, so `docker compose restart` will not pick them up:

```bash
docker compose up -d --build kamailio     # or freeswitch
```

`verify-08` step 6 catches this by diffing the running Kamailio config against
the repository.

**Never bind a configuration value to a FreeSWITCH global (`$${...}`).**
`autoload_configs` is loaded alphabetically, so `sofia.conf.xml` and the
dialplan can be read *before* the `<variables>` block in `switch.conf.xml`,
leaving the value empty. It looks correct after `reloadxml`, which makes it hard
to spot. For this reason codec preferences and the trunk gateway name are
substituted into templates (`*.tmpl`) from `.env`.

**A new `.env` variable must be declared in three places:** `.env(.example)`,
the `VARS` allowlist in `freeswitch/entrypoint.sh`, and the `environment` block
of the relevant service in `docker-compose.yml`. Miss one and envsubst writes an
empty string, silently dropping the setting.

**Port equality:** for `FS_EXT_SIP_PORT` the host port must equal the container
port. FreeSWITCH writes the *profile* port into Contact/Via, and `ext-sip-port`
does not affect Contact in this build; if the ports differ, in-dialog requests
are lost.

**`${domain_name}` is never set in this stack** (authentication happens in
Kamailio, not the FreeSWITCH directory). Use `${sip_from_host}` in the dialplan.

**Never load `mod_cdr_pg_csv` without a `<schema>` block** — the field list is
never built and the process segfaults at the end of every call.

**After switching branches with `git checkout`, recreate the containers.**
Checkout can delete and recreate bind-mounted directories; the container keeps
the old inode, the mount breaks, and files vanish inside the container
(`No such file or directory`) while still present on the host:

```bash
docker compose up -d --force-recreate
```

**Kamailio may start before FreeSWITCH, and that is normal.** Kamailio has no
`depends_on` for freeswitch (that would be a circular dependency). Because the
dispatcher resolves its target at startup, this used to make every call fail
with a permanent 503. Two measures are required together: an `extra_hosts`
mapping of `freeswitch` to a fixed IP, **and** `use_dns_cache=0` (Kamailio skips
`/etc/hosts` while its own DNS cache is enabled — inside the container
`getent hosts freeswitch` resolved correctly while Kamailio could not).
`verify-94-startup-order.sh` exercises this by stopping FreeSWITCH and
restarting Kamailio.

**Put schema changes in `db/init/`.** Those scripts only run against an *empty*
data directory, so applying `ALTER TABLE` to the running database is not
enough. `verify-92-fresh-schema.sh` proves the init scripts work by running
them in a throwaway database.

## Debugging

```bash
# SIP traffic (FreeSWITCH)
docker compose exec freeswitch fs_cli -p "$FS_ESL_PASSWORD" -x "sofia global siptrace on"
docker compose exec freeswitch tail -f /opt/freeswitch/var/log/freeswitch/freeswitch.log

# live registrations (NOT the DB: usrloc db_mode=2 is write-back, the table lags)
docker compose exec kamailio kamcmd ul.dump

# dispatcher targets
docker compose exec kamailio kamcmd dispatcher.list

# the live, parsed FreeSWITCH configuration (the REAL value, not the file)
docker compose exec freeswitch fs_cli -p "$FS_ESL_PASSWORD" -x "xml_locate configuration configuration name sofia.conf"

# CDRs
docker compose exec postgres psql -U kamailio -d kamailio \
  -c "SELECT tenant_id,caller_id_number,destination_number,duration,billsec,hangup_cause FROM cdr ORDER BY id DESC LIMIT 10;"
```

`tools/sip-call-probe.py` and `tools/sip-uas-probe.py` place real SIP calls
without a softphone and verify the media path by counting RTP echo.

## Known limitations

- **Half-finished SIP flows:** calls where the client never sends ACK used to
  segfault FreeSWITCH. The root cause (the `mod_cdr_pg_csv` schema) is fixed and
  `verify-08` step 9 guards against regressions.
- The `trusted` ACL allows all of `172.16.0.0/12`, so another Docker project on
  the same host could reach FreeSWITCH's internal profile.
- Event Socket (8021) is published; firewall it on a real server.
- Audio *quality* (jitter, dropouts) is not measured automatically — verify by
  ear.
- Inbound trunk calls, TLS/SRTP, voicemail and IVR are out of scope.

## Layout

```
db/init/          schema + seed (only run against an empty data directory)
kamailio/         Dockerfile + kamailio.cfg (baked into the image)
freeswitch/       Dockerfile, entrypoint.sh, conf/ (*.tmpl -> rendered), scripts/
xmlapi/           tenant-aware directory + dialplan (mod_xml_curl)
scripts/          verify-*.sh verification scripts
tools/            add-user.sh, sip-call-probe.py, sip-uas-probe.py
```
