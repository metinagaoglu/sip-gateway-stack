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

For a browser client instead of a softphone, see **Browser client (WebRTC)**
below; it registers over WSS on a different port and needs no `/etc/hosts`
entry.

## Adding users and tenants

```bash
./tools/add-user.sh <user> <password> <domain>
```

The script computes `ha1` with the correct realm. If you insert rows by hand:
`ha1 = md5(user:domain:password)`.

Tenancy relies on `use_domain=1`: `alice@tenant1` and `alice@tenant2` are
**different** users, and one tenant's password will not unlock the other's
account. This behaviour is verified by `scripts/verify-91-tenant-isolation.sh`.

## Browser client (WebRTC)

A browser can register over SIP-over-WSS and call an extension or a
UDP-registered softphone. nginx terminates TLS on `WEB_TLS_PORT`, serves the
client page and proxies `/ws` to Kamailio's WebSocket socket, which stays
inside the compose network and is never published. Media does not pass
through nginx or Kamailio: it flows directly between the browser and
FreeSWITCH as DTLS-SRTP, and FreeSWITCH transcodes OPUS to PCMU for the UDP
leg.

Get `EXTERNAL_IP` right before anything else — see the note in `.env.example`.
A wrong value here does not fail loudly: FreeSWITCH advertises an unreachable
media address, the DTLS handshake stalls at `HANDSHAKE` with silence in both
directions, and signalling still looks completely healthy, which reads like a
WebRTC bug rather than the configuration mismatch it actually is.

```bash
docker compose up -d --build web
open https://<EXTERNAL_IP>:<WEB_TLS_PORT>/
```

The certificate is self-signed, so accept the browser warning once. It is
generated at first start with `EXTERNAL_IP` in its subjectAltName and kept in
a named volume, so the exception survives a rebuild. Page and WebSocket share
one origin, so one exception covers both. If `EXTERNAL_IP` changes, the
volume still holds the old certificate (the entrypoint never overwrites an
existing one) and its subjectAltName no longer matches; delete the
`voip_web_certs` volume so the next start reissues it.

| Field | Value |
|---|---|
| Username | `alice` |
| Password | `alice123` |
| Domain | `tenant1.voip.local` |

The page no longer prefills the password field, but keep `WEB_TLS_PORT`
reachable only from a trusted LAN while these seeded credentials exist:
anyone who reaches the port can still type `alice123` from this table, and
once `TRUNK_ENABLED=true` that account can place outbound calls.

**Grant the microphone permission, then reload the page.** Chrome only
publishes real local ICE candidates if the microphone permission already
exists *when the page's `RTCPeerConnection` is created*; granting it during
the call itself is too late. If the browser hasn't held the permission since
page load, its candidates are all mDNS `.local` names, FreeSWITCH cannot
resolve them, and the call does not "connect with no audio" — it fails
outright: FreeSWITCH answers `488`, the page log shows
`cagri basarisiz: Incompatible SDP`, and the CDR shows
`hangup_cause=INCOMPATIBLE_DESTINATION` with `duration=0`. Grant the
permission once, reload the page, and the next call succeeds normally.

**Only the browser-originated direction works.** Calling a browser client
from a UDP softphone does not: signalling reaches FreeSWITCH as plain UDP
SIP, so it offers `RTP/AVP` and the browser rejects media without DTLS. That
direction needs SDP mangling and is not implemented — see
`docs/superpowers/specs/2026-08-13-webrtc-wss-kamailio-design.md`.

Verified end to end: a browser call to `9999` came back with echoed audio
(CDR `duration=2`, `billsec=2`, `NORMAL_CLEARING`), and a browser call to a
UDP-registered softphone carried two-way audio for its full length (CDR
`duration=31`, `billsec=27`, `NORMAL_CLEARING`). FreeSWITCH negotiates the
WebRTC offer arriving over plain UDP SIP with no configuration change at all:
DTLS goes `OFF` → `HANDSHAKE` → `SETUP` → `READY`, it logs
`audio Fingerprint Verified.` and
`Secure Type: srtp:dtls:AES_CM_128_HMAC_SHA1_80`, and answers with
`m=audio 16400 UDP/TLS/RTP/SAVPF 111 110`.

**Candidate selection is rescued by symmetric RTP, not correct.** FreeSWITCH
logs `NO candidate ACL defined, Defaulting to wan.auto` and, tested with two
VPN tunnels active on the host, was observed advertising a virtual/VPN
adapter address (`198.19.254.2`) instead of the real LAN address. The call
still worked only because symmetric RTP re-latched onto the true source
(`Auto Changing audio stun/rtp/dtls port from 198.19.254.2:51149 to
172.30.0.1:25534`). Treat this as a caveat, not a guarantee — a host without
that latching behaviour could fail on the same misdetection instead of
recovering from it.

**Known issue, not diagnosed: hanging up has been reported as not working**
even on calls where audio was fine. Server-side evidence points away from a
routing failure — the CDR shows `NORMAL_CLEARING` and there is no
`loose_route` warning for the in-dialog BYE — so the likely cause is
client-side UI state in `web/client.js`, not a signalling bug. No fix is
applied yet.

The published RTP range allows roughly six concurrent calls once both legs
are counted; raise `RTP_END` before increasing concurrency.

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
