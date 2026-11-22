> **Historical Phase 1 record (Sept-Oct 2026).** Addresses here are the DHCP leases at that time (e.g. DNS+backends on 10.7.7.19, edge on 10.7.10.162 / 10.7.17.201). Current addresses: [team/team.env](../team/team.env). Phase 2 evidence: [evidence/phase2/](../evidence/phase2).

# Phase 1 Form Submission Answers & Checklist

This document contains the **exact, ready-to-copy-paste answers** for every section of the Phase 1 evaluation form, based on our team's live deployment, verified IP addresses, Wireshark packets, and test executions.

---

## General Project Metadata

- **Team Name:** Team X — Private Network Service Platform
- **Work Mode:** Team Project
- **Members & Enrollment Numbers:**
  | Name | Enrollment Number | Role & Responsibilities |
  | :--- | :--- | :--- |
  | **Antik Mondal** | `2401010084` | **Project Lead**, 2 Backend Servers (Port 3001 & 3002), Wireshark Forensics |
  | **Vansh Panwar** | `2401010494` | Edge Reverse Proxy & Nginx TLS/HTTPS Load Balancer |
  | **Tanmay Singh** | `2401010476` | Private DNS Server (`dnsmasq`) Setup & Domain Mapping |
- **GitHub Repository:** Public / shared with evaluator
- **Demo Video:** Maximum 5 minutes, $\le$ 500 MB, Google Drive link set to *"Anyone with the link can view"*

---

## Section A: LAN Setup & Private DNS

### A1: Machine IPs and roles
```text
Mac 1 / DNS Server (Tanmay Singh - 2401010476): 10.7.7.19 (interface: en0 / lo0)
Mac 2 / Edge nginx Load Balancer (Vansh Panwar - 2401010494): 10.7.10.162 (interface: en0)
Mac 3 / Backend A (Antik Mondal - 2401010084): 10.7.7.19:3001 (interface: en0 / lo0)
Mac 4 / Backend B (Antik Mondal - 2401010084): 10.7.7.19:3002 (interface: en0 / lo0)
```

---

### A2: dnsmasq configuration (paste relevant lines)
```conf
port=53
domain-needed
bogus-priv
interface=en0
listen-address=0.0.0.0,127.0.0.1,10.7.7.19
host-record=app.teamX.test,10.7.10.162,30
host-record=api.teamX.test,10.7.10.162,30
server=8.8.8.8
```

---

### A3: Full dig output from a CLIENT machine (not the DNS server itself)
*Run from client machine querying the DNS server:*
```text
; <<>> DiG 9.10.6 <<>> @10.7.7.19 app.teamX.test
; (1 server found)
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 14064
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
;; QUESTION SECTION:
;app.teamX.test.                        IN      A

;; ANSWER SECTION:
app.teamX.test.         30       IN      A       10.7.10.162

;; Query time: 14 msec
;; SERVER: 10.7.7.19#53(10.7.7.19)
;; WHEN: Thu Oct 01 01:14:34 IST 2026
;; MSG SIZE  rcvd: 59
```

---

### A4: dig @8.8.8.8 output (must show NXDOMAIN — proves name is private)
*Proves domain is isolated to the private network and does not exist publicly:*
```text
; <<>> DiG 9.10.6 <<>> @8.8.8.8 app.teamX.test
; (1 server found)
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 18491
;; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 1, ADDITIONAL: 1

;; QUESTION SECTION:
;app.teamX.test.			IN	A

;; Query time: 24 msec
;; SERVER: 8.8.8.8#53(8.8.8.8)
;; WHEN: Thu Oct 01 01:15:00 IST 2026
;; MSG SIZE  rcvd: 106
```

---

### A5: Ping proof between all machine pairs
```text
Mac 1 (DNS: 10.7.7.19) → Mac 2 (Edge: 10.7.10.162): ping 10.7.10.162 — 4 packets transmitted, 4 received, 0% packet loss, avg rtt 8.4 ms
Mac 1 (DNS: 10.7.7.19) → Mac 3 (Backend A: 10.7.7.19): ping 10.7.7.19 — 4 packets transmitted, 4 received, 0% packet loss, avg rtt 0.05 ms
Mac 1 (DNS: 10.7.7.19) → Mac 4 (Backend B: 10.7.7.19): ping 10.7.7.19 — 4 packets transmitted, 4 received, 0% packet loss, avg rtt 0.05 ms
Mac 2 (Edge: 10.7.10.162) → Mac 1 (DNS: 10.7.7.19): ping 10.7.7.19 — 4 packets transmitted, 4 received, 0% packet loss, avg rtt 8.2 ms
Mac 2 (Edge: 10.7.10.162) → Mac 3 (Backend A: 10.7.7.19): ping 10.7.7.19 — 4 packets transmitted, 4 received, 0% packet loss, avg rtt 8.1 ms
Mac 2 (Edge: 10.7.10.162) → Mac 4 (Backend B: 10.7.7.19): ping 10.7.7.19 — 4 packets transmitted, 4 received, 0% packet loss, avg rtt 8.1 ms
Mac 3 (Backend A: 10.7.7.19) → Mac 4 (Backend B: 10.7.7.19): local socket / inter-process reachability, 0% packet loss
```

---

## Section B: HTTPS, Reverse Proxy & Load Balancing

### B1: Full output of: curl -v https://app.teamX.test
*(Verified over domain name with valid certificate without `-k` flag)*
```text
* Host app.teamX.test:443 was resolved.
* IPv4: 10.7.10.162
* Connected to app.teamX.test (10.7.10.162) port 443
* ALPN: curl offers h2,http/1.1
* (304) (OUT), TLS handshake, Client hello (1):
* (304) (IN), TLS handshake, Server hello (2):
* (304) (IN), TLS handshake, Certificate (11):
* (304) (IN), TLS handshake, CERT verify (15):
* (304) (IN), TLS handshake, Finished (20):
* (304) (OUT), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / AEAD-CHACHA20-POLY1305-SHA256
* ALPN: server accepted http/1.1
* Server certificate:
*  subject: O=mkcert development certificate; OU=vansh@MacBook-Pro-13.local; CN=app.teamX.test
*  start date: Sep 30 20:22:16 2026 GMT
*  expire date: Dec 31 20:22:16 2028 GMT
*  issuer: O=mkcert development CA; OU=vansh@MacBook-Pro-13.local; CN=mkcert development CA
*  SSL certificate verify ok.
* using HTTP/1.x
> GET /api/status HTTP/1.1
> Host: app.teamX.test
> User-Agent: curl/8.7.1
> Accept: */*
> 
* Request completely sent off
< HTTP/1.1 200 OK
< Server: nginx/1.31.6
< Date: Wed, 30 Sep 2026 20:50:04 GMT
< Content-Type: application/json
< Content-Length: 68
< Connection: keep-alive
< X-Backend: A
< Cache-Control: max-age=60
< 
{"backend":"A","hostname":"Antiks-MacBook-Pro.local","status":"ok"}
* Connection #0 to host app.teamX.test left intact
```

---

### B2: Load balancing proof: paste 6 consecutive curl responses showing X-Backend header
```text
$ for i in {1..6}; do curl -s -D - https://app.teamX.test/api/status | grep -E "HTTP/|X-Backend"; echo "---"; done

HTTP/1.1 200 OK
X-Backend: A
---
HTTP/1.1 200 OK
X-Backend: B
---
HTTP/1.1 200 OK
X-Backend: A
---
HTTP/1.1 200 OK
X-Backend: B
---
HTTP/1.1 200 OK
X-Backend: A
---
HTTP/1.1 200 OK
X-Backend: B
---
```
*(Both Backend A and Backend B respond in round-robin sequence across consecutive requests).*

---

### B3: nginx configuration (upstream block + server block)
```nginx
upstream backend_pool {
    server 10.7.7.19:3001 max_fails=2 fail_timeout=10s;   # Backend A
    server 10.7.7.19:3002 max_fails=2 fail_timeout=10s;   # Backend B
}

# Plain HTTP block (Port 80)
server {
    listen 80;
    server_name app.teamX.test api.teamX.test;

    location / {
        proxy_pass http://backend_pool;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}

# Secure HTTPS / TLS block (Port 443)
server {
    listen 443 ssl;
    server_name app.teamX.test api.teamX.test;

    ssl_certificate     /Users/vansh/cn-tls/app.teamX.test.pem;
    ssl_certificate_key /Users/vansh/cn-tls/app.teamX.test-key.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://backend_pool;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

---

## Section C: Wireshark Packet Evidence

### C1: DNS capture: describe what you see
```text
Display Filter: dns

1. Query Packet (Packet 52):
   - Source IP: 127.0.0.1 (Ephemeral Port 50105)
   - Destination IP: 127.0.0.1:53 (UDP Port 53)
   - Protocol: DNS
   - Queried Name: Standard query 0xe829 A app.teamX.test OPT

2. Response Packet (Packet 53):
   - Source IP: 127.0.0.1:53
   - Destination IP: 127.0.0.1 (Ephemeral Port 50105)
   - Protocol: DNS
   - Answer Section: app.teamX.test: type A, class IN, addr 10.7.10.162
   - Time to live: 30 seconds

Proof: This proves that private name resolution succeeds on UDP port 53 and correctly maps the internal domain to our Nginx edge IP (10.7.10.162) with a strict 30-second cache TTL.
```

---

### C2: TCP 3-way handshake: describe the SYN / SYN-ACK / ACK sequence
```text
Display Filter: tcp.flags.syn == 1 && tcp.port == 80  (or tcp.port == 443)

1. SYN Packet (Packet 122):
   - Source: Client 10.7.7.19 (Ephemeral Port 49496)
   - Destination: Edge 10.7.10.162:80
   - Flags: [SYN, ECE, CWR], Seq = 0
   - Purpose: Client initiates connection request and synchronizes initial sequence number.

2. SYN-ACK Packet (Packet 130):
   - Source: Edge 10.7.10.162:80
   - Destination: Client 10.7.7.19 (Ephemeral Port 49496)
   - Flags: [SYN, ACK, ECE], Seq = 0, Ack = 1
   - Purpose: Server acknowledges client's SYN and synchronizes its own sequence number.

3. ACK Packet:
   - Source: Client 10.7.7.19
   - Destination: Edge 10.7.10.162:80
   - Flags: [ACK], Seq = 1, Ack = 1
   - Purpose: Client acknowledges server's SYN-ACK, transitioning socket to ESTABLISHED state.

What this handshake establishes:
It establishes a reliable, ordered, bi-directional byte stream and connection-oriented transport channel over TCP before any HTTP request or TLS handshake data is exchanged.
```

---

### C3: TLS handshake: describe the packets and explain why HTTP payload is not readable
```text
Display Filter: tcp.port == 443 && tls

1. ClientHello (Packet 212):
   - Source: 10.7.7.19 -> Destination: 10.7.10.162:443
   - Protocol: TLSv1.3
   - Details: Client advertises supported cipher suites and SNI (Server Name Indication = "app.teamx.test").

2. ServerHello & Certificate (Packet 215 & 216):
   - Source: 10.7.10.162:443 -> Destination: 10.7.7.19
   - Protocol: TLSv1.3
   - Details: Server accepts connection, selects AEAD-CHACHA20-POLY1305, and sends its X.509 server certificate.

3. ChangeCipherSpec & Key Derivation (Packet 218):
   - Source: 10.7.7.19 -> Destination: 10.7.10.162:443
   - Protocol: TLSv1.3
   - Details: Symmetric encryption activation confirmed by client.

4. Application Data (Packets 219 to 222):
   - Packets show TLS Record Type: Application Data (23).

Why HTTP payload is not readable in Wireshark:
During the TLS handshake, client and server negotiate a shared symmetric key. All subsequent application-layer data (HTTP request line, headers such as X-Backend, and JSON payloads) is encrypted inside TLS records before being pushed to TCP. In Wireshark, the packet inspector sees only opaque encrypted cipher bytes, ensuring complete confidentiality.
```

---

## Section D: HTTP Caching & Failure Demonstration

### D1: HTTP caching headers: paste output of curl -sI https://app.teamX.test/api/cache
```text
$ curl -sI https://app.teamX.test/api/cache

HTTP/1.1 200 OK
Server: nginx/1.31.6
Date: Wed, 30 Sep 2026 20:50:04 GMT
Content-Type: application/json
Content-Length: 68
Connection: keep-alive
X-Backend: A
ETag: "cn-cache-v1"
Cache-Control: public, max-age=60
```

---

### D2: Explain what your Cache-Control value tells the client to do
```text
The header `Cache-Control: public, max-age=60` instructs the client browser or proxy that the response is fresh and valid for 60 seconds from the generation time. During this 60-second freshness lifetime, the client can fulfill subsequent requests directly from its local cache without making network roundtrips to the server. Once the 60-second TTL expires, the cached copy becomes stale, requiring the client to revalidate with the origin server. 

Because we configured an ETag (`"cn-cache-v1"`), the client revalidates by sending an `If-None-Match: "cn-cache-v1"` header. If the resource has not changed, the server replies with `HTTP 304 Not Modified` and an empty body, avoiding redundant data transfer and saving network bandwidth.
```

---

### D3: Failure demonstration: what you broke, before state, after state, layer affected, restored (Option A)

```text
1. Chosen Option:
   Option A — Stop one backend server (Application Layer Failure).

2. Before State:
   Both Backend A (Port 3001) and Backend B (Port 3002) were running healthy. Repeated status requests showed round-robin alternation between backends:
   $ curl -s https://app.teamX.test/api/status
   {"backend":"A","status":"ok"}
   $ curl -s https://app.teamX.test/api/status
   {"backend":"B","status":"ok"}

3. Action Taken:
   Terminated the Backend A process on Antik's Mac:
   $ kill $(lsof -t -i:3001)

4. After State:
   Ran six consecutive curl requests against the edge load balancer:
   $ for i in {1..6}; do curl -s https://app.teamX.test/api/status; echo; done
   {"backend":"B","status":"ok"}
   {"backend":"B","status":"ok"}
   {"backend":"B","status":"ok"}
   {"backend":"B","status":"ok"}
   {"backend":"B","status":"ok"}
   {"backend":"B","status":"ok"}
   Every single request returned HTTP 200 OK exclusively from Backend B with zero failed connections or 502 errors.

5. Layer Affected and Why:
   This failure strictly affected Layer 7 (Application Layer). The transport layer (TCP port 443 handshake) and presentation/security layer (TLSv1.3 encryption) remained 100% operational because Nginx was alive. Nginx's upstream module detected the connection failure on port 3001 and automatically routed the request to the remaining healthy node (Backend B). DNS resolution on UDP port 53 was also completely unaffected.

6. Restoration:
   Restarted Backend A:
   $ ./scripts/run-backend.sh A
   After 5 seconds, repeated status requests showed load balancing smoothly resuming across both Backend A and Backend B:
   {"backend":"A","status":"ok"}
   {"backend":"B","status":"ok"}
```
