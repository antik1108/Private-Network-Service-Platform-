# Phase 2 Runbook — Setup, Demo Sequence, Rollback

Everything here is copy-paste ready. Commands that need an admin password are marked **(sudo)**; everything else runs as a normal user.

## 0. Roles and addresses (verified 23 Nov 2026)

| Mac | Owner | Roles in Phase 2 | IP (en0, /19) | Services |
| --- | --- | --- | --- | --- |
| **Mac 1** | Tanmay Singh (2401010476) | Primary DNS + test client | `10.7.6.8` | dnsmasq :53 |
| **Mac 2** | Vansh Panwar (2401010494) | Primary edge (nginx) + **backup DNS** | `10.7.31.150` | nginx :80/:443, dnsmasq :53 |
| **Mac 3/4** | Antik Mondal (2401010084) | Backend A + Backend B + **standby edge** + test client | `10.7.22.168` | Flask :3001, :3002, nginx :80/:443 |

LAN `10.7.0.0/19` (mask 255.255.224.0), gateway `10.7.0.1`, interface `en0`. College Wi-Fi uses DHCP, so **re-check the IPs before every session** (section 1).

The single source of truth is [`team/team.env`](../team/team.env). Every config is rendered from it by `scripts/render-configs.sh` into [`config/rendered/`](../config/rendered).

## 1. Start of session (every time)

On each Mac: `scripts/get-my-ip.sh`. If anything changed, edit `team/team.env` on the operator Mac (Antik), then:

```bash
scripts/deploy.sh
```

This renders every config, copies it to `~/cn-project/` on all three Macs over SSH, and starts DNS on Mac 1 and Mac 2, nginx on Mac 2 and Mac 3, and both backends on Mac 3. It finishes with a status table. Add `--tls` to re-issue the edge certificate.

Per-node control is available on each Mac (no sudo):

```bash
~/cn-project/bin/cn.sh status
~/cn-project/bin/cn.sh dns start|stop|reload|status
~/cn-project/bin/cn.sh dns-record <ip>          # repoint app/api.teamX.test, live reload
~/cn-project/bin/cn.sh edge start|stop|status
~/cn-project/bin/cn.sh backend start|stop A|B
```

## 2. One-time admin steps (sudo)

| Where | Command | Why |
| --- | --- | --- |
| Each client Mac (Antik, Tanmay; optionally Vansh) | `sudo ~/cn-project/bin/client-setup.sh` (or `sudo scripts/phase2/client-setup.sh` in the repo) | Sets Wi-Fi DNS to `10.7.6.8, 10.7.31.150`, removes the stale `/etc/resolver/test`, trusts the team CA, flushes the cache. Undo with `--undo`. |
| Mac 3/4 (Antik), for Extension C only | `sudo scripts/phase2/firewall.sh apply` → demo → `sudo scripts/phase2/firewall.sh rollback` | Backend isolation with pf. |
| Client, for the Extension B flush demo | `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` | Manual DNS cache flush. |

Nothing else needs root. dnsmasq (port 53) and nginx (ports 80/443) bind the wildcard address, which macOS lets ordinary users do.

## 3. Final demonstration sequence (Section 8 of the brief)

| # | Step | Command(s) | What to point at |
| --- | --- | --- | --- |
| 1 | Topology & inventory | Open [`docs/architecture.md`](architecture.md) | Diagram, IP table, service map |
| 2 | All on the LAN | `scripts/phase2/run-tests.sh p1` (Task A part), or `ping -c 2 <ip>` on each Mac | IPs, 0% loss |
| 3 | Resolve the private name | `dig app.teamX.test` | `SERVER: 10.7.6.8#53`, answer `10.7.31.150`, TTL ≤ 30 |
| 4 | HTTPS by name | `curl -v https://app.teamX.test/api/status` (no `-k`), or a browser | `SSL certificate verify ok`, `HTTP/2 200` |
| 5 | Load balancing | `for i in {1..6}; do curl -sI https://app.teamX.test/api/status \| grep -i x-backend; done` | A, B, A, B … |
| 6 | Wireshark | Open `evidence/phase2/captures/phase1-full-flow-lan.pcapng` | See [evidence/phase2/README.md](../evidence/phase2/README.md) for frame numbers |
| 7 | Caching | `curl -I https://app.teamX.test/api/cache`, then `curl -i -H 'If-None-Match: "cn-cache-v1"' https://app.teamX.test/api/cache` | `Cache-Control: public, max-age=60`, `ETag`, `304` |
| 8 | Fail one backend | `scripts/phase2/run-tests.sh extD` | All 200 via B, then A rejoins |
| 9 | Phase 2 DNS resilience | `scripts/phase2/run-tests.sh extA`, `extB`, `extE` | Backup DNS answers; TTL countdown; edge cutover |
| 10 | Faculty-injected fault | `scripts/diagnose.sh` (then `DEEP=1 scripts/diagnose.sh`) | First failing layer + cause; see section 5 |
| 11 | Viva | [`docs/viva-prep.md`](viva-prep.md) | — |

## 4. Extension commands in detail

### A — Backup DNS
```bash
dig app.teamX.test                          # SERVER 10.7.6.8
ssh tanmaysingh@10.7.6.8 '~/cn-project/bin/cn.sh dns stop'
dig app.teamX.test                          # "connection refused" for 10.7.6.8, then answered by 10.7.31.150
curl -sI https://app.teamX.test/api/status  # still 200 once the cached entry expires (≤30 s)
ssh tanmaysingh@10.7.6.8 '~/cn-project/bin/cn.sh dns start'
```

### B — TTL and record change
```bash
dig @10.7.6.8 app.teamX.test +noall +answer           # TTL 30
dscacheutil -q host -a name app.teamX.test            # client caches 10.7.31.150
# change the record on BOTH resolvers
ssh tanmaysingh@10.7.6.8 '~/cn-project/bin/cn.sh dns-record 10.7.22.168'
ssh vansh@10.7.31.150    '~/cn-project/bin/cn.sh dns-record 10.7.22.168'
while true; do date +%T; dscacheutil -q host -a name app.teamX.test | grep ip_; dig @10.7.6.8 app.teamX.test +short; sleep 5; done
# client keeps the old IP until the TTL runs out, then switches. Flush to switch at once:
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```
Change the record back the same way (`dns-record 10.7.31.150`).

### C — Service isolation (sudo on Mac 3/4)
```bash
sudo scripts/phase2/firewall.sh apply
scripts/phase2/run-tests.sh extC            # edge 200, client times out, client-via-edge 200
sudo scripts/phase2/firewall.sh status      # rule counters show the dropped SYNs
sudo scripts/phase2/firewall.sh rollback    # restore original pf state
```

### D — HA failover
```bash
scripts/phase2/run-tests.sh extD
# or by hand:
~/cn-project/bin/cn.sh backend stop A ; for i in {1..6}; do curl -sI https://app.teamX.test/api/status | grep -i x-backend; done
~/cn-project/bin/cn.sh backend start A ; sleep 11 ; (repeat loop: A and B again)
```
Remaining single point of failure: the edge (nginx on Mac 2), and also the backend host, since both backends run on one Mac. See the report for how to remove them.

### E — DNS-based edge cutover
```bash
scripts/phase2/run-tests.sh extE
```

## 5. Troubleshooting drill (Extension F)

Run `scripts/diagnose.sh` on a client. It checks layers bottom-up and stops at the **first failing layer**:

| Layer | Check | Failure signature → likely fault |
| --- | --- | --- |
| L1 | `ipconfig getifaddr en0` | no IP → Wi-Fi/DHCP |
| L2 | `dig @dns1`, `dig @dns2`, system resolver | NXDOMAIN/no answer → dnsmasq down or record removed. Servers OK but system fails → wrong client DNS setting. Servers disagree → zone out of sync. Answer not an edge IP → wrong record |
| L3 | reachability of resolved IP | no reply → host off, wrong IP |
| L4 | `nc -z ip 443` | *refused* (fast) → nginx down / wrong port. *timeout* → firewall drop |
| L5 | `openssl s_client -verify_return_error` | verify error → wrong cert / SAN / untrusted CA / expired |
| L6 | `curl https://…/api/status` | 404 → server_name/location. 502/504 → see L7 |
| L7 | edge → backend (`DEEP=1`) | refused → backend stopped. Timeout → backend firewall / wrong upstream IP |

Practice faults and their recorded diagnoses: [evidence/phase2/logs/extF-drills.log](../evidence/phase2/logs/extF-drills.log).

## 6. Rollback / shutdown

```bash
sudo scripts/phase2/firewall.sh rollback           # if pf was applied
sudo scripts/phase2/client-setup.sh --undo         # restore the client's old DNS servers
for n in tanmaysingh@10.7.6.8 vansh@10.7.31.150; do ssh $n '~/cn-project/bin/cn.sh dns stop; ~/cn-project/bin/cn.sh edge stop'; done
~/cn-project/bin/cn.sh edge stop; ~/cn-project/bin/cn.sh backend stop
```
The original nginx site config on Mac 2 was saved to `~/cn-project/backup/cn-project.conf.orig`.
