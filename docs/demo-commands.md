> **Updated 25 Nov 2026:** DNS primary is Mac 1 `10.7.6.8` (backup Mac 2 `10.7.31.150`), edge `10.7.31.150`, backends `192.168.1.188:3001/3002`. Mac 2 currently cannot reach Mac 3's backend ports across the separate Wi-Fi networks; reconnect to the same college Wi-Fi or establish a route/VPN before the full demo. Since Phase 2, backends accept direct connections **only from the edge** while the pf firewall is applied, so run step 5 from Mac 2. Config now lives in `~/cn-project/` (see [phase2-runbook.md](phase2-runbook.md)). Full Phase 1+2 demo sequence: [phase2-runbook.md](phase2-runbook.md#3-final-demonstration-sequence-section-8-of-the-brief).

# Phase 1 Live Demo Commands

Run each command in the designated location as specified. These commands follow the exact evaluation flow for testing and recording video demonstrations.

---

## 1. Show DNS Configuration

**On DNS Server (Mac 1):**
```bash
cat ~/cn-project/dnsmasq/dnsmasq.conf ~/cn-project/dnsmasq/teamX.hosts
```
*Show: listen-address, port 53, domain definitions, and host-record mappings with 30s TTL.*

---

## 2. Show Backend Configurations & Code

**On Backend Machines:**
```bash
cat backend/app.py
```
*Show: `/`, `/api/status`, `/api/cache`, `X-Backend` header injection, and `0.0.0.0` listening binding.*

---

## 3. Show nginx Edge Configuration

**On Edge / Load Balancer (Mac 2):**
```bash
cat /opt/homebrew/etc/nginx/servers/cn-project.conf   # installed from ~/cn-project/nginx/
```
*Show: upstream block with both backend IPs/ports, `listen 443 ssl`, certificate paths, and `proxy_pass`.*

---

## 4. Test DNS Resolution (Section A)

**From any client Mac:**
```bash
dig @10.7.6.8 app.teamX.test
```
*Expected: Answer section shows Mac 2 IP (`10.7.31.150`) with 30s TTL.*

**Public DNS Isolation Check:**
```bash
dig @8.8.8.8 app.teamX.test
```
*Expected: NXDOMAIN or timeout (confirming private isolation).*

---

## 5. Test Backend Endpoints Directly

**From Mac 2 or Client:**
```bash
curl -i http://192.168.1.188:3001/api/status
curl -i http://192.168.1.188:3002/api/status
```
*Expected: HTTP 200 with headers `X-Backend: A` and `X-Backend: B` respectively.*

---

## 6. Test Trusted HTTPS (Section B1)

**From Client Mac:**
```bash
curl -v https://app.teamX.test
```
*Expected: Certificate verify OK without using `-k`, HTTP/2 negotiated, HTTP 200 response.*

---

## 7. Test HTTP Protocol Versions (Section B)

```bash
curl --http1.1 -I https://app.teamX.test/api/status
curl --http2 -I https://app.teamX.test/api/status
```
*Expected: Status lines show `HTTP/1.1 200 OK` and `HTTP/2 200` respectively.*

---

## 8. Test Round-Robin Load Balancing (Section B2)

Run 6 times sequentially:
```bash
curl -i https://app.teamX.test/api/status
```
*Expected: Alternating or distributed responses showing `X-Backend: A` and `X-Backend: B`.*

---

## 9. Test HTTP Caching & Conditional Requests (Section D1, D2)

```bash
# 1. First fetch - check Cache-Control and ETag headers:
curl -I https://app.teamX.test/api/cache

# 2. Conditional fetch - should return 304 Not Modified:
curl -i -H 'If-None-Match: "cn-cache-v1"' https://app.teamX.test/api/cache
```
*Expected:*
- Request 1: `HTTP/2 200`, `Cache-Control: public, max-age=60`, `ETag: "cn-cache-v1"`.
- Request 2: `HTTP/2 304 Not Modified` with empty body.

---

## 10. Wireshark Live Packet Capture (Section C)

1. Flush local DNS cache:
   ```bash
   sudo dscacheutil -flushcache
   sudo killall -HUP mDNSResponder
   ```
2. Identify network interface:
   ```bash
   route -n get 10.7.31.150
   ```
3. Start Wireshark capture on the identified interface (`en0` / `lo0`).
4. Execute test commands:
   ```bash
   dig @10.7.6.8 app.teamX.test
   curl --tlsv1.2 --tls-max 1.2 -v https://app.teamX.test
   ```
5. Stop Wireshark capture and save `.pcapng`.

**Wireshark Filter Reference:**
- **DNS Query/Response:** `dns && ip.addr == 10.7.6.8`
- **TCP 3-Way Handshake:** `tcp.flags.syn == 1 && tcp.port == 443` $\to$ follow stream `tcp.stream eq 0`
- **TLS Handshake & Encrypted Data:** `tcp.stream eq 0 && tls`

---

## 11. Backend Failure & Fault Tolerance (Section D3)

1. Stop Backend A (terminate process on Port 3001).
2. Execute status requests:
   ```bash
   curl -i https://app.teamX.test/api/status
   ```
   *Expected: All responses smoothly handled by Backend B (`X-Backend: B`).*
3. Restart Backend A:
   ```bash
   ./scripts/run-backend.sh A
   ```
4. Repeat requests:
   *Expected: Round-robin balancing between A and B resumes automatically.*
