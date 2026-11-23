# Presentation Guide: Understand It, Practice It, Present It

This guide explains the whole project in plain language: what each piece is, why it exists, who runs it, what happens when you type a command, and exactly what to show the faculty.

---

## Part 1 — The big picture in one minute

We built a **tiny private internet** out of three laptops on the college Wi-Fi.

When someone types `https://app.teamX.test` on a team Mac:

1. The Mac asks **"what is the address of app.teamX.test?"** → our own **DNS server** answers.
2. The Mac connects to that address → our **edge server (nginx)**, the single front door.
3. The connection is **encrypted (HTTPS/TLS)**, and the browser checks our **certificate** to make sure it's really our server.
4. nginx passes the request to one of two **backend apps** (A or B), taking turns: **load balancing**.
5. The answer travels back, and each response says which backend handled it (`X-Backend: A` or `B`).

Phase 2 makes it **survive failures**: a second DNS server, a firewall around the backends, automatic failover when a backend dies, a standby front door, and a tool that finds faults layer by layer.

> **Core idea for the faculty:** "The app is deliberately simple — it just returns JSON. The *network* is the project."

### An analogy you can use

| Real world | Our project |
| --- | --- |
| Phone book / directory enquiry | **DNS** (dnsmasq): turns a name into an address |
| A second phone book in another room | **Backup DNS** on Mac 2 |
| "This phone book entry is valid for 30 seconds" | **TTL** |
| Hotel reception desk: every guest goes through it | **Edge / reverse proxy** (nginx) |
| Receptionist sending guests to whichever clerk is free | **Load balancer** (round robin) |
| Sealed envelope + ID card the guest checks | **TLS encryption + certificate** |
| The clerks in the back office | **Backends A and B** (Flask apps) |
| Security guard letting only reception into the back office | **Firewall** (pf) |
| Receptionist noticing a clerk is absent and sending guests to the other one | **Health check / failover** |
| A second reception desk you can switch to | **Standby edge** |

---

## Part 2 — Who runs what

| Machine | Person | IP (23 Nov) | What runs there | Role in the analogy |
| --- | --- | --- | --- | --- |
| **Mac 1** | Tanmay | `10.7.6.8` | **dnsmasq** (primary DNS), test client | The main phone book |
| **Mac 2** | Vansh | `10.7.31.150` | **nginx** edge (ports 80/443) + **backup dnsmasq** | Reception desk + spare phone book |
| **Mac 3/4** | Antik | `10.7.22.168` | **Backend A** (port 3001), **Backend B** (port 3002), **standby nginx**, **pf firewall**, test client | The back office (two clerks) + spare reception desk |

We are 3 people, so Mac 3 and Mac 4 share one laptop: two separate programs on two separate ports. The brief allows this.

```
                         College Wi-Fi  (10.7.0.0/19, router 10.7.0.1)
   ┌──────────────────┐        ┌──────────────────────────┐        ┌───────────────────────────┐
   │ Mac 1  (Tanmay)  │        │ Mac 2  (Vansh)           │        │ Mac 3/4  (Antik)          │
   │ 10.7.6.8         │        │ 10.7.31.150              │        │ 10.7.22.168               │
   │                  │        │                          │        │                           │
   │ DNS #1 :53       │        │ nginx EDGE :443  ────────┼──────► │ Backend A :3001           │
   │ (dnsmasq)        │        │  (TLS, load balancer)    │        │ Backend B :3002           │
   │                  │        │ DNS #2 :53 (backup)      │        │ standby nginx :443        │
   │ test client      │        │                          │        │ pf firewall               │
   └──────────────────┘        └──────────────────────────┘        └───────────────────────────┘
          ▲  DNS question                ▲  HTTPS                        ▲ only Mac 2 may enter
          └──────────────── any client Mac (Mac 1 or Mac 3/4) ───────────┘
```

---

## Part 3 — The journey of ONE request, step by step

Command on a client: `curl -v https://app.teamX.test/api/status`

| Step | What happens | Protocol / port | Who |
| --- | --- | --- | --- |
| 1 | The Mac asks "IP of app.teamX.test?" | **DNS** over **UDP port 53** | client → Mac 1 |
| 2 | dnsmasq answers "10.7.31.150, valid for 30 s" | DNS reply | Mac 1 → client |
| 3 | The client opens a connection: **SYN → SYN-ACK → ACK** | **TCP** port **443** | client ↔ Mac 2 |
| 4 | **TLS handshake**: ClientHello → ServerHello + **certificate** → key exchange → Finished. Now everything is encrypted | **TLS** | client ↔ Mac 2 |
| 5 | The client checks the certificate: is it for `app.teamX.test`, and signed by a CA I trust? Yes → padlock | — | client |
| 6 | The client sends `GET /api/status` (encrypted, **HTTP/2**) | HTTPS | client → Mac 2 |
| 7 | nginx decrypts it and picks a backend (A, then B, then A, …) | — | Mac 2 |
| 8 | nginx makes a **new**, plain HTTP connection to the backend | HTTP/1.1, TCP **3001** or **3002** | Mac 2 → Mac 3/4 |
| 9 | The backend answers JSON + header `X-Backend: A` | HTTP | Mac 3/4 → Mac 2 |
| 10 | nginx adds `X-Edge: edge1-mac2`, encrypts it, sends it back | HTTPS | Mac 2 → client |

**Key sentence:** *"DNS only finds the address. It does not connect anything. The connection is TCP, the security is TLS, and the request itself is HTTP."*

**Why doesn't the client know the backend IPs?** It only ever talks to the edge. We can move, add or remove backends without touching any client, just like a cloud load balancer.

### Layers (OSI / TCP-IP)

| Layer | In our project |
| --- | --- |
| Application | DNS, HTTP |
| Session / Presentation | TLS (encryption) |
| Transport | TCP (web), UDP (DNS); ports 53, 443, 3001, 3002 |
| Network | IP addresses 10.7.x.x, ICMP (ping, "port unreachable") |
| Link | Wi-Fi (en0), MAC addresses, ARP |

---

## Part 4 — Every component explained

### 4.1 The LAN (Task A)
- **What:** all Macs on the same Wi-Fi network, `10.7.0.0/19` (mask 255.255.224.0), gateway `10.7.0.1`.
- **Why:** nothing else works unless the machines can reach each other.
- **Show it:** `scripts/get-my-ip.sh` on each Mac, then `ping -c 3 <other IP>`.
- **Gotcha:** college Wi-Fi uses DHCP, so **IPs change when you reconnect**. That's why every config is generated from `team/team.env`.

### 4.2 DNS — dnsmasq (Task B, Mac 1)
- **What:** a small DNS server that knows our private names: `app.teamX.test` and `api.teamX.test` → `10.7.31.150` (the edge).
- **Why `.test`?** It's reserved for private use. `.local` would clash with Apple's mDNS (Bonjour).
- **Other names** (google.com etc.) are forwarded to the college DNS, so the internet still works.
- **Records file:** `~/cn-project/dnsmasq/teamX.hosts` (one line: `10.7.31.150 app.teamX.test api.teamX.test`).
- **Show it:** `dig app.teamX.test` → look for `ANSWER: 10.7.31.150`, `30` (TTL) and `SERVER: 10.7.6.8#53`.
- **Proof it's private:** `dig @8.8.8.8 app.teamX.test` → `NXDOMAIN` (the public internet has never heard of it).

### 4.3 Backup DNS (Extension A, Mac 2)
- **What:** an identical dnsmasq on Vansh's Mac with the same records.
- **Why:** if Mac 1 dies, nobody can resolve names: the whole service looks "down" even though it's fine.
- **How clients use it:** each client's DNS list is `10.7.6.8, 10.7.31.150`. If the first doesn't answer, the Mac asks the second.
- **What you'll see:** stop DNS on Mac 1 → `dig @10.7.6.8` times out, but `curl https://app.teamX.test` still works.
- **Key difference:** *DNS failure* = the name can't be found, so nothing even starts. *Application failure* = the name resolves and the connection works, but the edge returns **502**.

### 4.4 TTL (Extension B)
- **What:** every DNS answer comes with "you may remember this for **30 seconds**".
- **Why it matters:** if we change the record, clients keep using the **old** address until their 30 s runs out.
- **Show it:** change the record → `dig @10.7.6.8` shows the new IP **immediately**, but the client (`dscacheutil -q host -a name app.teamX.test`) shows the **old** one for ~30 s, then switches.
- **Flush:** `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` → the client forgets and switches **instantly**.
- **Real world:** companies lower the TTL before a migration, switch, then wait at least one old TTL before turning off the old server.

### 4.5 The edge — nginx (Task D, Mac 2)
- **What:** the single front door. Clients only ever talk to it.
- **Reverse proxy:** it receives the request and makes its own request to a backend on the client's behalf.
- **Load balancer:** **round robin**: A, B, A, B…
- **Show it:** run the same request 6 times and watch `x-backend` alternate.
- **Port 80 → 443:** plain HTTP is redirected to HTTPS (`301`).
- **Cloud equivalent:** AWS Application Load Balancer, GCP Load Balancer.

### 4.6 HTTPS / TLS / certificate (Task E)
- **What:** nginx holds a certificate for `app.teamX.test`, signed by our own little CA (made with **mkcert** on Vansh's Mac).
- **Trust:** each client Mac has our CA in its **System keychain**, so curl and browsers accept the certificate with **no warnings and no `-k`**.
- **TLS termination:** encryption ends at nginx. Behind it (nginx → backend) is plain HTTP on our trusted LAN.
- **Handshake to explain:** ClientHello (says "I want app.teamX.test") → ServerHello + Certificate → key exchange → Finished → encrypted data.
- **Why the payload is unreadable in Wireshark:** after the handshake, everything is encrypted with session keys only the two ends know.
- **Why we captured with TLS 1.2:** in TLS 1.3 the certificate itself is encrypted, so you can't see it in Wireshark.
- **HTTP/2** is used between client and nginx (`ALPN: h2`).

### 4.7 The backends (Task C, Mac 3/4)
- **What:** one small Python Flask program (`backend/app.py`) started twice: as **A on port 3001** and **B on port 3002**.
- **Endpoints:** `/` (hello JSON), `/api/status` (`{"backend":"A","status":"ok"}`), `/api/cache` (the caching demo).
- **Header:** `X-Backend: A` or `B`, so we can see who answered.
- **Listens on 0.0.0.0** (all interfaces), not 127.0.0.1; otherwise other Macs couldn't reach it.

### 4.8 Caching (Task F)
- `/api/cache` returns `Cache-Control: public, max-age=60` and `ETag: "cn-cache-v1"`.
- **Fresh hit:** within 60 s the browser reuses its copy and sends no request at all.
- **Conditional request:** after that, it asks "has `cn-cache-v1` changed?" (`If-None-Match`) → server says **304 Not Modified** with no body (saves bandwidth).
- **Full request:** no validator → **200** with the full body.
- `/api/status` is `no-store` (live data is never cached).

### 4.9 Firewall — pf (Extension C, Mac 3/4)
- **What:** macOS's packet filter, with rules that say **only Mac 2 (the edge) may connect to ports 3001/3002**.
- **Why:** clients must always go through the front door. Nobody should bypass the TLS, load balancing and logging.
- **What you'll see:** from Mac 2 → backend: `200`. From Mac 1 → backend: **timeout**. From Mac 1 → through the edge: `200`.
- **Drop vs refused:** our firewall silently **drops** the packet, so the client waits and **times out** (curl exit 28). A stopped backend instead answers **"connection refused"** at once (curl exit 7). Same symptom ("doesn't work"), different cause.
- **Rollback:** the script saved the original state. `rollback` removes our rules.
- **Cloud equivalent:** a security group allowing the backend port only from the load balancer.

### 4.10 Failover / health checks (Extension D)
- **What:** nginx notices when a backend stops answering.
- **How:** if connecting to A fails, nginx **immediately retries the same request on B** (`proxy_next_upstream`), so the user never sees an error. It then marks A "down" for **10 seconds** (`max_fails=1 fail_timeout=10s`). After 10 s it tries A again, and if A is back, round robin resumes.
- **Proof in the log** (Mac 2, `~/cn-project/logs/nginx-access.log`): `upstream=…:3001, …:3002 upstream_status=502, 200`, meaning "A failed, B served it".
- **Still a single point of failure:** the **edge** (one nginx, one IP). And in our 3-person setup, Antik's laptop (both backends live there). Fix: floating IP with VRRP/keepalived, or a managed cloud load balancer.

### 4.11 Standby edge / DNS cutover (Extension E)
- **What:** a second nginx on Antik's Mac with the **same config and the same certificate**.
- **Cutover:** change the DNS record from `10.7.31.150` → `10.7.22.168`.
- **What you'll see:** a Mac that looks up the name fresh goes to the **new** edge immediately (`X-Edge: edge2-mac3`). A Mac that cached the old answer keeps going to the **old** edge for up to 30 s, then moves.
- **Why the same certificate works:** TLS checks the **name**, not the IP.

### 4.12 Troubleshooting tool (Extension F)
- `scripts/diagnose.sh` checks layer by layer, from the bottom up, and stops at the **first broken layer**:
  **L1** my network → **L2** DNS → **L3** can I reach the IP → **L4** is the port open (refused vs timeout) → **L5** TLS/certificate → **L6** HTTP status → **L7** edge → backend.
- **Fault signatures:**

| What you see | Broken layer | Typical cause |
| --- | --- | --- |
| Name doesn't resolve | L2 DNS | dnsmasq stopped, wrong client DNS setting |
| Resolves to a non-edge IP | L2 (wrong record) | Someone changed the record |
| Connection refused (instant) | L4 | nginx stopped / wrong port |
| Connection timeout | L4 filtered | Firewall dropping packets |
| Certificate error | L5 TLS | Wrong / expired cert, untrusted CA |
| HTTP 404 | L6 | nginx `server_name` / location wrong |
| HTTP 502 | L7 | Backends down, wrong upstream address, firewall blocking the edge |

> **Real example from 23 Nov 10:30:** Antik's laptop joined a different Wi-Fi (192.168.1.x). The tool reported DNS OK, TCP OK, TLS OK, **HTTP 502 → L7 edge→backend**. The backends were running, but the edge could no longer reach that laptop. Exactly what the tool predicts.

---

## Part 5 — Before the presentation (do this every time)

1. **All three Macs on the SAME Wi-Fi** (college Wi-Fi). Check on each:
   ```bash
   scripts/get-my-ip.sh
   ```
2. **If any IP changed**, edit `team/team.env` on Antik's Mac (MAC1/2/3_IP, DNS1/2, EDGE1/2, BACKEND_A/B, APP_RECORD_IP), then:
   ```bash
   scripts/deploy.sh
   ```
   This regenerates every config, copies it to all Macs over SSH, starts everything, and prints a status table.
3. **Clients** (Antik, Tanmay): if your IP changed, the DNS servers in Wi-Fi settings must be updated too:
   ```bash
   sudo scripts/phase2/client-setup.sh
   ```
4. **Tailscale DNS off** on Antik's Mac (Tailscale menu → untick "Use Tailscale DNS settings").
5. **Final check:**
   ```bash
   scripts/smoke-test.sh
   scripts/diagnose.sh        # should end with "All layers healthy"
   ```

---

## Part 6 — The live demo script (Section 8 of the brief)

Run these from **Antik's Mac** unless stated otherwise. "Say" = what to explain.

### Step 1 — Topology and inventory
Open `docs/architecture.md` (diagram + IP table).
**Say:** "Three Macs on the college LAN. Mac 1 is DNS, Mac 2 is the edge plus backup DNS, Mac 3/4 runs two backends and a standby edge."

### Step 2 — All on the LAN
```bash
scripts/get-my-ip.sh
ping -c 3 10.7.6.8
ping -c 3 10.7.31.150
```
**Say:** "Every machine reaches every other machine. 0% packet loss."

### Step 3 — Resolve the name
```bash
dig app.teamX.test
dig @8.8.8.8 app.teamX.test
```
**Point at:** `SERVER: 10.7.6.8#53`, answer `10.7.31.150`, TTL `30`. Public DNS → `NXDOMAIN`.
**Say:** "Our own DNS server answers. The name only exists inside our network."

### Step 4 — HTTPS by name, no warnings
```bash
curl -v https://app.teamX.test/api/status
```
**Point at:** `SSL certificate verify ok`, `subject … app.teamX.test`, `ALPN: server accepted h2`, `HTTP/2 200`. No `-k`. Optionally open it in Safari: padlock, no warning.

### Step 5 — Load balancing
```bash
for i in 1 2 3 4 5 6; do curl -sI https://app.teamX.test/api/status | grep -i x-backend; done
```
**Say:** "Same name, same edge. nginx alternates A, B, A, B: round robin."

### Step 6 — Wireshark
Open `evidence/phase2/captures/phase1-full-flow-lan.pcapng` in Wireshark.
- Filter `dns` → frames 1–4: query to 10.7.6.8 port 53, answer 10.7.31.150 TTL 30.
- Filter `tcp.flags.syn==1` → frames 5–6: SYN, SYN-ACK to port 443 (client port is random/ephemeral, e.g. 53151).
- Filter `tls.handshake` → frame 8 ClientHello (SNI app.teamx.test), frame 11 ServerHello + **Certificate**, 12 ServerKeyExchange, 14/16 ChangeCipherSpec.
- Filter `tls.app_data` → encrypted data; the content can't be read.

### Step 7 — Caching
```bash
curl -I https://app.teamX.test/api/cache
curl -i -H 'If-None-Match: "cn-cache-v1"' https://app.teamX.test/api/cache
```
**Point at:** `cache-control: public, max-age=60`, `etag`, then `HTTP/2 304` with no body.

### Step 8 — Kill one backend
```bash
~/cn-project/bin/cn.sh backend stop A
for i in 1 2 3 4 5 6; do curl -sI https://app.teamX.test/api/status | grep -iE '^HTTP|x-backend'; done
~/cn-project/bin/cn.sh backend start A
sleep 11; for i in 1 2 3 4; do curl -sI https://app.teamX.test/api/status | grep -i x-backend; done
```
**Say:** "All 200, all B. nginx noticed A was gone and retried on B. After 10 s it tried A again and round robin is back."
Optional, on Vansh's Mac: `tail -5 ~/cn-project/logs/nginx-access.log` shows `upstream_status=502, 200`.

### Step 9 — Phase 2 DNS resilience (pick A, B or E; A is quickest)
**Backup DNS (A):**
```bash
ssh tanmaysingh@10.7.6.8 '~/cn-project/bin/cn.sh dns stop'
dig @10.7.6.8 app.teamX.test +time=2 +tries=1     # timed out: primary is dead
dig @10.7.31.150 app.teamX.test +short            # backup still answers
curl -sI https://app.teamX.test/api/status | head -1   # service still works
ssh tanmaysingh@10.7.6.8 '~/cn-project/bin/cn.sh dns start'
```
**TTL (B):** `scripts/phase2/run-tests.sh extB`, then explain the countdown output.
**Edge cutover (E):** `scripts/phase2/run-tests.sh extE`, and watch `edge1-mac2` turn into `edge2-mac3` after ~30 s.
**Firewall (C):**
```bash
sudo scripts/phase2/firewall.sh apply
ssh vansh@10.7.31.150 'curl -s -o /dev/null -w "edge: %{http_code}\n" http://10.7.22.168:3001/api/status'
ssh tanmaysingh@10.7.6.8 'curl -s -m 4 http://10.7.22.168:3001/api/status; echo "client exit=$?"'
sudo scripts/phase2/firewall.sh rollback
```
Edge: `200`. Client: `exit=28` (timeout = blocked).

### Step 10 — Faculty injects a fault
Stay calm and run:
```bash
scripts/diagnose.sh
DEEP=1 scripts/diagnose.sh     # also tests edge → backends from Mac 2
```
**Say out loud, bottom-up:** "First I check my own network… DNS resolves… TCP to 443 is open… TLS verifies… HTTP gives 502, so the edge is alive but can't reach the backends. Let me check the backends…" Then fix it with `cn.sh` (start the stopped service, `dns-record` to fix a record, `edge start` to reinstall the nginx config).

### Step 11 — Viva
Each person reads `docs/viva-prep.md`. Answer in your own words.

---

## Part 7 — Who presents what (suggestion)

| Person | Explains and demos |
| --- | --- |
| **Tanmay** | Steps 2–3: LAN, DNS, TTL, backup DNS (Ext A/B) |
| **Vansh** | Steps 4–5, 7–8: nginx edge, TLS/certificate, load balancing, caching, failover (Ext D) |
| **Antik** | Steps 1, 6, 9–10: topology, Wireshark, firewall (Ext C), edge cutover (Ext E), troubleshooting (Ext F) |

Everyone must still be able to explain **any** part: the faculty can ask anyone anything.

---

## Part 8 — Handy commands

| Want to… | Command |
| --- | --- |
| See everything on a Mac | `~/cn-project/bin/cn.sh status` |
| Start / stop DNS | `~/cn-project/bin/cn.sh dns start` / `stop` |
| Change the DNS record | `~/cn-project/bin/cn.sh dns-record <ip>` (run on Mac 1 **and** Mac 2) |
| Start / stop nginx | `~/cn-project/bin/cn.sh edge start` / `stop` |
| Start / stop a backend | `~/cn-project/bin/cn.sh backend start A` / `stop B` |
| Redeploy everything after an IP change | `scripts/deploy.sh` |
| Quick end-to-end check | `scripts/smoke-test.sh` |
| Find a fault | `scripts/diagnose.sh` |
| Watch DNS queries live (Mac 1/2) | `tail -f ~/cn-project/logs/dnsmasq.log` |
| Watch which backend served each request (Mac 2) | `tail -f ~/cn-project/logs/nginx-access.log` |

## Part 9 — If something goes wrong during the demo

| Symptom | Fix |
| --- | --- |
| `dig` shows `SERVER: 100.100.100.100` | Tailscale DNS is on: turn it off in the Tailscale menu |
| Everything gives 502 | Backends not reachable: is Antik's Mac on the same Wi-Fi? `cn.sh backend status` |
| Name doesn't resolve | `cn.sh dns status` on Mac 1/2; client DNS = `10.7.6.8, 10.7.31.150`? |
| Certificate warning | CA not trusted on that Mac: `sudo scripts/phase2/client-setup.sh` |
| Someone's IP changed | update `team/team.env` → `scripts/deploy.sh` → `sudo scripts/phase2/client-setup.sh` on clients |
