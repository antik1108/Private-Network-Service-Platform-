# Project Playbook, Troubleshooting & Operation Guide

A complete, step-by-step master reference documenting the architecture, entire setup process, every problem encountered and its exact resolution, runbook commands, and Wireshark forensic procedures.

---

## Table of Contents
1. [Architecture & Roles Overview](#1-architecture--roles-overview)
2. [End-to-End Golden Setup Path](#2-end-to-end-golden-setup-path)
3. [Problems Faced & Exact Resolutions (Post-Mortem)](#3-problems-faced--exact-resolutions-post-mortem)
4. [Operation & Disaster Recovery Runbook](#4-operation--disaster-recovery-runbook)
5. [Wireshark Forensics Master Cheatsheet](#5-wireshark-forensics-master-cheatsheet)
6. [Viva & Evaluation Defense Points](#6-viva--evaluation-defense-points)

---

## 1. Architecture & Roles Overview

The platform creates an isolated, enterprise-grade 3-tier network request flow across machines on the local area network (`10.7.x.x`):

```
[ Client Mac ]
      �      ├── 1. DNS Query (UDP 53) ──────► Mac 1 (Antik: 10.7.7.19)
                                        Service: dnsmasq
                                        Resolves: app.teamX.test -> 10.7.17.201 (TTL: 30s)
      │
      └── 2. HTTPS/TLS (TCP 443) ─────► Mac 2 (Vansh: 10.7.17.201)
                                        Service: nginx (Reverse Proxy + TLSv1.3 Termination)
                                        Upstream Balancing: Round-Robin
                                        │
                                        ├── 3a. HTTP/1.1 TCP 3001 ──► Backend A (Antik: 10.7.7.19)
                                        └── 3b. HTTP/1.1 TCP 3002 ──► Backend B (Antik: 10.7.7.19)
```

### Project Members & Responsibilities

| Name | Enrollment | Work mode | Role & Node Responsibilities |
| --- | --- | --- | --- |
| **Antik Mondal** | `2401010084` | Team (Lead) | Project Lead, 2 Backend Servers (Port 3001 & 3002 on his Mac), Wireshark Forensics |
| **Vansh Panwar** | `2401010494` | Team | Edge Reverse Proxy & Nginx TLS/HTTPS Load Balancer Setup (Mac 2) |
| **Tanmay Singh** | `2401010476` | Team | Private DNS Server (`dnsmasq`) Setup & Domain Mapping (Mac 1) |

### Node Inventory & Mapping

| Machine | Role | Member Assigned | Hostname / IP | Service | Port | Key Configuration File |
| --- | --- | --- | --- | --- | --- | --- |
| **Mac 1** | Private DNS | Tanmay Singh (`2401010476`) | `10.7.7.19` | `dnsmasq` | UDP/TCP `53` | `/opt/homebrew/etc/dnsmasq.conf` |
| **Mac 2** | Edge / TLS Terminator / Load Balancer | Vansh Panwar (`2401010494`) | `10.7.17.201` | `nginx` | TCP `80`, `443` | `/opt/homebrew/etc/nginx/servers/cn-project.conf` |
| **Mac 3** | Application Node A | Antik Mondal (`2401010084`) | `10.7.7.19` | Python Flask | TCP `3001` | `backend/app.py` (`BACKEND_ID=A`) |
| **Mac 4** | Application Node B | Antik Mondal (`2401010084`) | `10.7.7.19` | Python Flask | TCP `3002` | `backend/app.py` (`BACKEND_ID=B`) |

---

## 2. End-to-End Golden Setup Path

### Step 1: DNS Server Setup (Mac 1 — Antik)
1. Install dnsmasq:
   ```bash
   brew install dnsmasq
   ```
2. Configure `/opt/homebrew/etc/dnsmasq.conf`:
   ```conf
   port=53
   domain-needed
   bogus-priv
   interface=lo0
   listen-address=127.0.0.1,10.7.7.19
   host-record=app.teamX.test,10.7.17.201,30
   host-record=api.teamX.test,10.7.17.201,30
   server=8.8.8.8
   ```
3. Start service:
   ```bash
   sudo brew services restart dnsmasq
   ```
4. Verify:
   ```bash
   dig @127.0.0.1 app.teamX.test +short
   # Output: 10.7.17.201
   ```sh
   dig @127.0.0.1 app.teamX.test +short
   # Output: 10.7.10.162
   ```

### Step 2: Python Backends (Mac 3 & Mac 4 — Antik)
Both backends run from the root of `cn-starter`:
```bash
# Terminal 1 (Backend A):
./scripts/run-backend.sh A

# Terminal 2 (Backend B):
./scripts/run-backend.sh B
```
Verify locally:
```bash
curl -i http://127.0.0.1:3001/api/status
curl -i http://127.0.0.1:3002/api/status
curl -i http://127.0.0.1:3001/api/cache
```

### Step 3: Nginx Edge Load Balancer & TLS (Mac 2 — Vansh)
1. Generate local trusted SSL certificate on Vansh's Mac:
   ```bash
   brew install mkcert
   mkcert -install
   mkdir -p ~/cn-tls && cd ~/cn-tls
   mkcert app.teamX.test
   ```
2. Configure `/opt/homebrew/etc/nginx/servers/cn-project.conf`:
   ```nginx
   upstream backend_pool {
       server 10.7.7.19:3001 max_fails=2 fail_timeout=10s;
       server 10.7.7.19:3002 max_fails=2 fail_timeout=10s;
   }

   server {
       listen 80;
       server_name app.teamX.test;
       location / {
           proxy_pass http://backend_pool;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
       }
   }

   server {
       listen 443 ssl;
       server_name app.teamX.test;

       ssl_certificate     /Users/vansh/cn-tls/app.teamX.test.pem;
       ssl_certificate_key /Users/vansh/cn-tls/app.teamX.test-key.pem;
       ssl_protocols       TLSv1.2 TLSv1.3;

       location / {
           proxy_pass http://backend_pool;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-Proto $scheme;
       }
   }
   ```
3. Test syntax & start:
   ```bash
   sudo nginx -t
   sudo brew services restart nginx
   ```

---

## 3. Problems Faced & Exact Resolutions (Post-Mortem)

### Problem 1: `curl /api/cache` gave `404 NOT FOUND`
- **Symptom:** Running `curl http://10.7.7.19:3001/api/cache` returned HTTP 404.
- **Root Cause:** The starter code in `backend/app.py` only defined `/` and `/api/status`. The course rubric (Section D1 & D2) explicitly requires `/api/cache` with `ETag` and `304 Not Modified` validation.
- **Resolution:**
  Updated `backend/app.py` with:
  ```python
  ETAG = '"cn-cache-v1"'

  @app.route("/api/cache")
  def cache():
      if request.headers.get("If-None-Match") == ETAG:
          resp = make_response("", 304)
          resp.headers["X-Backend"] = BACKEND_ID
          resp.headers["ETag"] = ETAG
          resp.headers["Cache-Control"] = "public, max-age=60"
          return resp

      resp = make_response(jsonify(backend=BACKEND_ID, message="CN cache example"))
      resp.headers["X-Backend"] = BACKEND_ID
      resp.headers["ETag"] = ETAG
      resp.headers["Cache-Control"] = "public, max-age=60"
      return resp
  ```

---

### Problem 2: Git Submodule Warning on Cloned Reference Project
- **Symptom:** Running `git add .` triggered:
  ```text
  warning: adding embedded git repository: Computer-Network-Project
  hint: You've added another git repository inside your current repository.
  ```
- **Root Cause:** The reference project `Computer-Network-Project` was cloned directly inside the workspace directory, containing its own `.git` directory.
- **Resolution:**
  1. Added `Computer-Network-Project/` to `.gitignore`.
  2. Untracked it from Git cache:
     ```bash
     git rm --cached -f Computer-Network-Project
     ```

---

### Problem 3: `curl: (7) Failed to connect ... port 443: Connection refused`
- **Symptom:** `curl http://app.teamX.test/api/status` (Port 80) worked, but `curl https://app.teamX.test/api/status` (Port 443) threw `Connection refused`.
- **Root Cause:** Nginx on Vansh's Mac (`10.7.10.162`) was active only on Port 80. The SSL certificate had not yet been generated and the `listen 443 ssl;` server block was disabled.
- **Resolution:**
  1. Generated SSL certificates on Vansh's Mac using `mkcert`.
  2. Activated the `listen 443 ssl;` block in `/opt/homebrew/etc/nginx/servers/cn-project.conf`.
  3. Restarted Nginx: `sudo brew services restart nginx`.
  4. Subsequent HTTPS request connected and negotiated `TLSv1.3`.

---

### Problem 4: DNS query for `app.teamX.test` NOT captured on Wireshark interface `en0`
- **Symptom:** In Wireshark on `Wi-Fi: en0`, filtering `dns && ip.addr == 10.7.7.19` showed only reverse DNS queries to `8.8.8.8` or mDNS, never the A-record query for `app.teamX.test`.
- **Root Cause:** The DNS server IP (`10.7.7.19`) was bound to the local Mac. Under macOS kernel routing, traffic from a local IP to a local IP is routed through **Loopback (`lo0`)**, never reaching the physical Wi-Fi interface (`en0`).
- **Resolution:**
  1. In Wireshark, pressed `Cmd + K` and selected **`Loopback: lo0`**.
  2. Ran `dig @127.0.0.1 app.teamX.test`.
  3. Filtered by `dns`: Immediately revealed **Packet 52 (Query)** and **Packet 53 (Response)**.

---

### Problem 5: Missing TTL in DNS Screenshot
- **Symptom:** First screenshot attempt for DNS answer details selected Packet 52 instead of Packet 53, so `Answers` was not visible.
- **Root Cause:** Packet 52 is the client **Query** (which only contains Questions). Packet 53 is the server **Response** (which contains Answers, TTL, and IP).
- **Resolution:**
  Selected Packet 53, expanded `Domain Name System (response) -> Answers -> app.teamX.test`, revealing:
  - `Time to live: 30`
  - `Address: 10.7.10.162`

---

## 4. Operation & Disaster Recovery Runbook

Use these procedures whenever servers shut down, fail to bind, or misbehave.

### Scenario A: Python Backends Crash or Won't Start (Port Conflict)
If port 3001 or 3002 is already occupied:
```bash
# 1. Identify which PID is holding port 3001 or 3002
lsof -nP -iTCP:3001 -sTCP:LISTEN
lsof -nP -iTCP:3002 -sTCP:LISTEN

# 2. Kill the hanging process
kill -9 <PID>

# 3. Relaunch cleanly
./scripts/run-backend.sh A
./scripts/run-backend.sh B
```

### Scenario B: Private DNS Server (`dnsmasq`) Fails or Doesn't Resolve
```bash
# 1. Check if dnsmasq is running
sudo brew services list | grep dnsmasq

# 2. Verify port 53 is listening
sudo lsof -nP -iUDP:53 -iTCP:53 -sTCP:LISTEN

# 3. Restart dnsmasq
sudo brew services restart dnsmasq

# 4. Flush macOS DNS cache
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder

# 5. Sanity check resolution
dig @127.0.0.1 app.teamX.test +short
```

### Scenario C: Nginx Reverse Proxy Crashes or Returns `502 Bad Gateway`
- **If Nginx refuses connection:**
  ```bash
  # Check config syntax
  sudo nginx -t

  # Check if port 80/443 is open
  sudo lsof -nP -iTCP:80,443 -sTCP:LISTEN

  # Restart Nginx
  sudo brew services restart nginx
  ```
- **If Nginx returns `502 Bad Gateway`:**
  Nginx cannot reach Backend A (`10.7.7.19:3001`) or Backend B (`10.7.7.19:3002`).
  - Verify backends are running on Antik's Mac: `curl http://10.7.7.19:3001/api/status`.
  - Check firewall settings on Antik's Mac: `System Settings -> Network -> Firewall`.

### Scenario D: Wi-Fi Reconnection Changes IP Addresses
When reconnecting to Wi-Fi, DHCP often assigns new IPs.
1. On each Mac, run:
   ```bash
   ./scripts/get-my-ip.sh
   ```
2. Update `team/team.env` with the new IPs.
3. Update `dnsmasq.conf` with new Nginx IP $\to$ restart `dnsmasq`.
4. Update `cn-project.conf` on Nginx with new Backend IPs $\to$ restart `nginx`.

---

## 5. Wireshark Forensics Master Cheatsheet

### Display Filters Cheat Sheet

| Forensic Target | Wireshark Display Filter | What to Look For |
| --- | --- | --- |
| **DNS Resolution** | `dns` | Packet Query (`app.teamX.test`) & Response (`10.7.10.162`) |
| **TCP Handshake (HTTP)** | `tcp.flags.syn == 1 && tcp.port == 80` | `[SYN]` from client, `[SYN, ACK]` from Nginx |
| **TCP Handshake (HTTPS)** | `tcp.flags.syn == 1 && tcp.port == 443` | `[SYN]` and `[SYN, ACK]` on secure port |
| **Entire Stream** | `tcp.stream eq 0` | Complete sequence from SYN $\to$ HTTP/TLS $\to$ FIN |
| **TLS Handshake & Data** | `tcp.port == 443 && tls` | `Client Hello`, `Server Hello`, `Certificate`, `Application Data` |

### Key Evidence Packets Captured in Live Session

```text
[Loopback: lo0]
Packet 52: 127.0.0.1 -> 127.0.0.1  DNS  Standard query A app.teamX.test OPT
Packet 53: 127.0.0.1 -> 127.0.0.1  DNS  Standard query response A 10.7.10.162 (TTL: 30)

[Wi-Fi: en0]
Packet 122: 10.7.7.19  -> 10.7.10.162 TCP  49496 -> 80 [SYN]
Packet 130: 10.7.10.162 -> 10.7.7.19  TCP  80 -> 49496 [SYN, ACK]

[Wi-Fi: en0 - TLSv1.3 Stream]
Packet 212: 10.7.7.19  -> 10.7.10.162 TLSv1.3  Client Hello (SNI = app.teamx.test)
Packet 215: 10.7.10.162 -> 10.7.7.19  TLSv1.3  Server Hello, Change Cipher Spec
Packet 216: 10.7.10.162 -> 10.7.7.19  TLSv1.3  Certificate & Verification Data
Packet 218: 10.7.7.19  -> 10.7.10.162 TLSv1.3  Change Cipher Spec
Packets 219-222:                       TLSv1.3  Encrypted Application Data
```

---

## 6. Viva & Evaluation Defense Points

When explaining this project to an evaluator or professor, emphasize these key networking concepts:

1. **Why is private DNS better than editing `/etc/hosts`?**
   - Editing `/etc/hosts` is static and non-scalable (every client device must be manually updated). A central DNS server (`dnsmasq`) dynamically provides name resolution, caching, and TTL policies to all network clients uniformly.
2. **Why does Wireshark show `Application Data` instead of HTTP headers?**
   - Because TLS terminates on Nginx. All application-layer HTTP requests and responses are encrypted by the symmetric cipher negotiated during the TLS handshake before transmission over TCP port 443.
3. **What is the significance of the 30-second TTL?**
   - The Time-to-Live dictates how long client operating systems cache the DNS answer. In a microservice or failover architecture, a short TTL (like 30s) ensures that if the edge IP changes, clients update within 30 seconds.
4. **How does fault tolerance work at the application layer?**
   - Nginx actively monitors upstream backend health via `max_fails` and `fail_timeout`. If Backend A terminates, Nginx transparently fails over to Backend B. The client never experiences a failed connection, and the TLS and TCP sessions remain completely undisturbed.
