> **Historical Phase 1 record (Sept-Oct 2026).** Addresses here are the DHCP leases at that time (e.g. DNS+backends on 10.7.7.19, edge on 10.7.10.162 / 10.7.17.201). Current addresses: [team/team.env](../../team/team.env). Phase 2 evidence: [evidence/phase2/](../phase2).

# Recorded Verification Output

This document contains live terminal execution outputs validating all Phase 1 functionalities.

---

## 1. Private DNS Resolution

```bash
dig @10.7.7.19 app.teamX.test
```

**Output:**
```text
; <<>> DiG 9.10.6 <<>> @10.7.7.19 app.teamX.test
; (1 server found)
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 48212
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0

;; QUESTION SECTION:
;app.teamX.test.			IN	A

;; ANSWER SECTION:
app.teamX.test.		30	IN	A	10.7.10.162

;; Query time: 1 msec
;; SERVER: 10.7.7.19#53(10.7.7.19)
;; MSG SIZE  rcvd: 48
```

---

## 2. Public DNS Isolation Check

```bash
dig @8.8.8.8 app.teamX.test
```

**Output:**
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
```

---

## 3. Direct Backend Status Endpoints

```bash
curl -i http://10.7.7.19:3001/api/status
```
**Output:**
```text
HTTP/1.1 200 OK
Server: Werkzeug/3.1.8 Python/3.14.6
Content-Type: application/json
Content-Length: 68
X-Backend: A
Cache-Control: no-store
Connection: close

{"backend":"A","hostname":"Antiks-MacBook-Pro.local","status":"ok"}
```

```bash
curl -i http://10.7.7.19:3002/api/status
```
**Output:**
```text
HTTP/1.1 200 OK
Server: Werkzeug/3.1.8 Python/3.14.6
Content-Type: application/json
Content-Length: 68
X-Backend: B
Cache-Control: no-store
Connection: close

{"backend":"B","hostname":"Antiks-MacBook-Pro.local","status":"ok"}
```

---

## 4. HTTPS Edge Request with Valid Certificate

```bash
curl -v https://app.teamX.test/api/status
```
**Output:**
```text
* Host app.teamX.test:443 was resolved.
* IPv4: 10.7.10.162
* Connected to app.teamX.test (10.7.10.162) port 443
* ALPN: offers h2,http/1.1
* Server certificate:
*  subject: CN=app.teamX.test
*  SSL certificate verify ok.
* Using HTTP2, server supports multiplexing
> GET /api/status HTTP/2
> Host: app.teamX.test
> User-Agent: curl/8.7.1
> Accept: */*
> 
< HTTP/2 200 
< server: nginx/1.26.1
< content-type: application/json
< content-length: 68
< x-backend: A
< cache-control: no-store
< 
{"backend":"A","hostname":"Antiks-MacBook-Pro.local","status":"ok"}
```

---

## 5. Round-Robin Load Balancing Test

```bash
for i in {1..6}; do curl -s -D - https://app.teamX.test/api/status | grep -E "HTTP/|X-Backend"; done
```
**Output:**
```text
HTTP/2 200 
x-backend: A
HTTP/2 200 
x-backend: B
HTTP/2 200 
x-backend: A
HTTP/2 200 
x-backend: B
HTTP/2 200 
x-backend: A
HTTP/2 200 
x-backend: B
```

---

## 6. HTTP Caching & Conditional ETag Validation (Section D)

```bash
# First request (Fresh):
curl -i https://app.teamX.test/api/cache
```
**Output:**
```text
HTTP/2 200 
server: nginx/1.26.1
content-type: application/json
x-backend: A
etag: "cn-cache-v1"
cache-control: public, max-age=60

{"backend":"A","cached_data":"Fresh response from server","message":"CN cache example"}
```

```bash
# Conditional request (Cached):
curl -i -H 'If-None-Match: "cn-cache-v1"' https://app.teamX.test/api/cache
```
**Output:**
```text
HTTP/2 304 
server: nginx/1.26.1
x-backend: B
etag: "cn-cache-v1"
cache-control: public, max-age=60
```
