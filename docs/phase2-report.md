# Phase 2 Final Report — Harden, Recover, and Troubleshoot

**Team:** Antik Mondal (2401010084, lead) · Vansh Panwar (2401010494) · Tanmay Singh (2401010476)
**Domain:** `teamX.test` · **Date of tests:** 23 Nov 2026 · **Network:** college Wi-Fi, 10.7.0.0/19

## 1. Starting point: what we found when we came back to the Phase 1 system

Two months after the Phase 1 review the system no longer worked. We diagnosed it layer by layer, the same way the brief asks for in Extension F:

| # | Symptom | Layer | Root cause | Fix |
| --- | --- | --- | --- | --- |
| 1 | `app.teamX.test` did not resolve on any Mac | L2 DNS | DHCP had moved every laptop (Antik 10.7.7.19 → 10.7.22.168, Vansh 10.7.17.201 → 10.7.31.150, Tanmay 10.7.16.222 → 10.7.6.8). dnsmasq on Antik failed to start (`listen-address=10.7.7.19` no longer existed), and records still pointed at the old edge IP | All IPs now live in one file (`team/team.env`); `render-configs.sh` + `deploy.sh` regenerate and push every config |
| 2 | `brew services` showed nginx in `error` on Mac 2 since 6 Nov | L5 TLS / L7 config | `cannot load certificate … app.teamX.test.pem: No such file`. The repo had been re-cloned and the gitignored key + cert were gone | Re-issued the certificate from Vansh's existing mkcert CA (same CA as Phase 1), SAN `app.teamX.test` + `api.teamX.test`, valid to Feb 2029. Key kept outside git in `~/cn-project/tls/` |
| 3 | Docs claimed HTTP/2 | — | nginx had `listen 443 ssl;` without `http2 on;`. Clients actually negotiated HTTP/1.1 | `http2 on;` (verified: `ALPN: server accepted h2`, `HTTP/2 200`) |
| 4 | DNS TTL shown as 0 in the last Phase 1 run | L2 | Records used `address=/…/ip`, which uses `local-ttl` (default 0) | Records moved to a hosts file with `local-ttl=30` |
| 5 | Antik's Mac resolved `*.test` only via itself | L2 client | Leftover `/etc/resolver/test → 127.0.0.1` | Removed by `client-setup.sh`; clients now list both team resolvers in Network → DNS |
| 6 | Docs inconsistent | docs | Mac 2 appeared as three different IPs; "Tanmay = DNS at 10.7.7.19" while that address was actually Antik's laptop; nginx template had a third backend IP and the HTTPS block commented out; README listed capture files that do not exist | Docs regenerated from the current inventory. Historical Phase 1 records kept as-is, with a dated note |
| 7 | Phase 1 evidence weakness | Task G | The Oct capture was on loopback (client = DNS server = backend host), the TCP handshake shown was to port 80, and TLS 1.3 hides the Certificate message | New cross-LAN capture (`evidence/phase2/captures/phase1-full-flow-lan.pcapng`) with TLS 1.2 so the Certificate is visible, plus a TLS 1.3/HTTP/2 stream for comparison |

## 2. What changed from Phase 1

| Component | Phase 1 | Phase 2 |
| --- | --- | --- |
| Roles | DNS + both backends effectively on one laptop | Mac 1 = primary DNS + client; Mac 2 = edge + **backup DNS**; Mac 3/4 = backends + **standby edge** + client |
| DNS | 1 resolver, TTL 0, records in the main config | 2 resolvers with identical zone, TTL 30, live reload via SIGHUP, `local=/teamX.test/` (project names never leak upstream), non-project names forwarded to college DNS then 8.8.8.8 |
| Clients | one resolver | `10.7.6.8, 10.7.31.150` |
| Edge | HTTP/1.1, plain upstream | HTTP/2, :80 → 301 → :443, `max_fails=1 fail_timeout=10s`, `proxy_next_upstream error timeout http_502/503/504`, 2 s connect timeout, `X-Edge` header, access log with `$upstream_addr`/`$upstream_status` |
| Backends | reachable from the whole LAN | pf anchor: only Mac 2 may connect to 3001/3002 |
| Operations | hand-edited files | `team.env` → `render-configs.sh` → `deploy.sh`; `cn.sh` per node; `diagnose.sh`; `run-tests.sh`; `fault-drills.sh` |
| Privileges | `sudo brew services` for dnsmasq/nginx | Services run **without root**: macOS lets unprivileged processes bind ports < 1024 on the wildcard address, so dnsmasq uses `bind-interfaces` + `listen-address=0.0.0.0`, and nginx uses `listen 443`. Root is needed only for client DNS settings, keychain trust, pf, and cache flush |

## 3. Resilience tests and results

All results come from logs in `evidence/phase2/logs/`.

| Test | Procedure | Expected | Observed | Result |
| --- | --- | --- | --- | --- |
| Phase 1 regression | `run-tests.sh p1` | name resolves via team DNS, HTTPS verifies, A/B alternate, 304 | Both resolvers answer `10.7.31.150` TTL 30; `SSL certificate verify ok`; HTTP/2 and HTTP/1.1; 8 requests B,A,B,A…; conditional GET → 304; :80 → 301 | PASS |
| §6.3 wrong DNS server | `dig @8.8.8.8`, `dig @10.7.22.168` | lookup fails, IP still reachable | NXDOMAIN / timeout; `nc` to 10.7.31.150:443 succeeds | PASS |
| §6.3 wrong record IP | curl pinned to Mac 1's IP | resolves, connects to wrong host | exit 7 (Mac 1 has no web server) | PASS |
| §6.3 one backend stopped | stop A | service continues | 4/4 `200 backend=B` | PASS |
| §6.3 both backends stopped | stop A+B | DNS + TLS fine, 502 | `SSL certificate verify ok`, `HTTP/2 502`, nginx: `no live upstreams` | PASS |
| §6.3 wrong port | `https://app.teamX.test:8443` | host up, port closed | exit 7 refused; :443 open | PASS |
| **A** backup DNS | stop dnsmasq on Mac 1 | clients keep resolving via Mac 2 | `dig @10.7.6.8` times out; system resolver still returns `10.7.31.150`; HTTPS 200; capture shows ICMP port-unreachable from Mac 1 and the answer from Mac 2 | PASS |
| **A** DNS vs app failure | backends stopped, DNS up | resolution works, service 502 | `dig` → `10.7.31.150`, curl → `HTTP 502` | PASS |
| **B** TTL | change record 10.7.31.150 → 10.7.22.168 | client keeps old answer ≤ TTL | server answered new at once; client kept `10.7.31.150` until +31…36 s, switched at +36…41 s (5 s polling, two runs); an earlier run behind Tailscale's DNS proxy took 42 s | PASS |
| **B** flush | `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` | immediate change | record reverted, client still cached `10.7.22.168`; right after the flush it returned `10.7.31.150` | PASS |
| **C** isolation | pf anchor on Mac 3/4 | edge 200, client blocked | edge → A/B `200`; client → A `000`/exit 28 (timeout), `nc` fails; client → edge 200; capture shows 10 unanswered SYNs vs edge SYN-ACK | PASS |
| **C** rollback | `sudo firewall.sh rollback` | original pf state | pf token released; Mac 1 → Backend A is `200` again (original open configuration) | PASS |
| **D** HA | stop A, 8 requests, restart A | all served by B; A rejoins | 8/8 `200 backend=B`; nginx: `connect() failed (61: Connection refused)`, `upstream server temporarily disabled`, access log `upstream_status=502, 200` (transparent retry); 11 s after restart: A,B,A,B | PASS |
| **E** cutover | record → standby edge | new lookups → edge2 at once; cached clients stay on edge1 ≤ TTL | Mac 1 (fresh lookup) immediately `x-edge: edge2-mac3`; Mac 3/4 (cached) stayed on `edge1-mac2` from +6 s to +31 s, moved to `edge2-mac3` at +35 s; edge1 then stopped with no client error; rolled back | PASS |
| **F** drills | 6 injected faults + `diagnose.sh` | correct first failing layer | see section 4 | PASS |

**Note on TTL timing.** In the first run, the operator Mac's Tailscale DNS proxy (100.100.100.100) sat in front of the system resolver with its own cache, and the switch took 42 s. With Tailscale DNS turned off it took 31–36 s (the client had cached the answer just before the change; we poll every 5 s). Lesson: every caching layer between client and authoritative server can stretch a cutover beyond the TTL.

## 4. Troubleshooting findings (Extension F)

`scripts/diagnose.sh` checks the layers in order and names the first one that fails: client IP → DNS (both servers + system resolver + "is the answer an edge IP?") → reachability → TCP (refused vs timeout) → TLS (`openssl s_client -verify_return_error`) → HTTP status → edge-to-backend.

| Drill | Injected fault | Diagnosis output | Lesson |
| --- | --- | --- | --- |
| 1 | Record points to Mac 1 (no web server) | DNS answers, WARN "10.7.6.8 is NOT one of the edges", connect refused → **L2 DNS (wrong record), seen at L4** | DNS succeeding proves nothing about the destination |
| 2 | Both resolvers stopped | **L2 DNS (servers)** | No name, no connection: nothing above L2 is tested |
| 3 | nginx stopped on the edge | **L4 TCP (refused)** — fast RST | Host up, port closed |
| 4 | Wrong upstream ports in nginx | TLS OK, **HTTP 502 → L7 edge→backend**; DEEP check shows backends healthy on the real ports | Backends fine, edge config wrong |
| 5 | Edge serving a cert for `wrong.test` | **L5 TLS** — verify error | Name/SAN/trust problems show up only at L5 |
| 6 | Both backends stopped | **HTTP 502 → L7** | Edge alive, application down |

Full output: `evidence/phase2/logs/extF-drills.log`.

Other real issues we hit while building Phase 2, each solved by isolating its layer:

- **Port 53 "Permission denied" without sudo.** dnsmasq binds each interface address separately on macOS, and only the wildcard bind is allowed for non-root users. Fix: `bind-interfaces` + `listen-address=0.0.0.0`.
- **Backend would not restart: "Address already in use".** Homebrew's framework Python re-launches itself as a child process, so our PID file pointed at the launcher. Fix: track the process that actually **listens** on the port (`lsof -iTCP:3001 -sTCP:LISTEN`).
- **dnsmasq log "missing" queries.** It logs names in lowercase (`app.teamx.test`), because DNS names are case-insensitive.
- **Tailscale overrides `/etc/resolv.conf`.** Plain `dig` asks 100.100.100.100, while curl/browsers use the system resolver. Turn off Tailscale DNS for the demo.
- **ICMP from automation was blocked** ("No route to host") while TCP worked. This is macOS local-network privacy for the calling app, not the network. Pings were run from the other Macs.

## 5. Learning summary (one paragraph per extension)

**A — Backup DNS.** Redundancy for name resolution comes from the *client* holding more than one resolver address, not from the server. When dnsmasq on Mac 1 stopped, the kernel answered our queries with ICMP port-unreachable, and the macOS resolver (which queries both servers in parallel) simply used the backup's answer. The key distinction: when DNS fails, the client never reaches TCP at all. When an application fails, DNS, TCP and TLS all succeed and the failure appears as an HTTP 502 from the edge.

**B — TTL.** The TTL is a promise we make to every cache: "you may reuse this answer for 30 s." The authoritative answer changed the instant we reloaded dnsmasq, but our client kept using the old IP until its cached entry expired, and an extra caching layer (Tailscale) stretched that further. In production, this is why teams lower TTLs hours before a migration, make the change, and wait at least one old TTL before decommissioning the old target. Flushing the cache only fixes the machines you control.

**C — Service isolation.** With pf we turned "the backends are on the LAN" into "the backends are reachable only from the edge", the same idea as a cloud security group that allows the backend port only from the load balancer. Using `block drop` meant a blocked client sees a timeout (SYNs retransmitted with no reply), which is clearly different from a stopped service (immediate RST, "connection refused"). Loading the rules into an anchor under `com.apple/*` let us add and remove them without editing `/etc/pf.conf`, and the rollback script restores the original state.

**D — HA failover.** Open-source nginx detects failure passively. One refused connection marks Backend A down for 10 s, and `proxy_next_upstream` retries the *same* request on Backend B, so clients saw 8/8 successes while A was dead. When A came back, the first request after `fail_timeout` probed it and round robin resumed. What remains a single point of failure is the edge itself (one nginx, one IP), and in our 3-person setup also the single backend host.

**E — Edge migration.** Because TLS authenticates the *name* and not the IP, a standby nginx holding the same certificate and key can take over just by changing one A record. A fresh lookup went to the standby immediately, while a client with a cached answer kept talking to the old edge until the TTL ran out. That is why the old edge must stay up (drain) for at least one TTL after cutover. Removing even that window needs an IP-level mechanism (VRRP/CARP floating IP) or a managed load balancer.

**F — Troubleshooting.** The most useful habit was refusing to guess. Every fault we injected showed a unique signature at exactly one layer: NXDOMAIN or no answer (L2), RST (L4 refused), silence (L4 filtered), certificate verify error (L5), 502 (edge alive, backends not). Testing bottom-up means that by the time a layer fails, every layer below it has already been proven good.

## 6. Remaining single points of failure and how to remove them

1. **Edge IP** → floating VIP with keepalived/CARP on Mac 2 and Mac 3, or multiple A records with health-checked DNS (Route 53 failover), or a managed LB.
2. **Backend host** → move Backend B to a separate (fourth) Mac.
3. **Zone sync** → real primary/secondary with AXFR + NOTIFY instead of pushing the same file to both.
4. **Certificate on two machines** → in production a secrets manager / ACM-style managed certificate instead of copying the key.
