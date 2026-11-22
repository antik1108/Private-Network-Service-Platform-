# Viva Preparation — Phase 1 + Phase 2

These are short answers to understand, not to read out. Every member should be able to explain all of them.

## The request journey (say this in one breath)
The client asks its DNS resolver (UDP 53, ephemeral source port) for `app.teamX.test`. dnsmasq on Mac 1 answers `10.7.31.150` with TTL 30, and the client caches it. The client opens TCP to 10.7.31.150:443 (SYN, SYN-ACK, ACK) and starts TLS: ClientHello with SNI `app.teamX.test` and ALPN h2; ServerHello plus the certificate signed by our mkcert CA, which the client trusts because the CA is in its System keychain; key exchange (ECDHE); Finished. HTTP/2 then runs inside the encrypted tunnel. nginx terminates TLS, picks a backend round-robin, and makes a new plain HTTP/1.1 connection to 10.7.22.168:3001 or :3002. The backend replies with `X-Backend`; nginx adds `X-Edge` and relays it back to the client.

## Phase 1 questions
- **DNS resolution vs connection?** DNS only maps a name to an IP; no connection to the service exists yet. A wrong DNS record still "succeeds" and simply sends you to the wrong host.
- **Why doesn't the client know backend IPs?** It only ever talks to the edge. The edge is the single entry point, so backends can be added, removed or moved without touching clients.
- **Why is the payload encrypted in Wireshark?** After the handshake, records are AES-GCM / ChaCha20 encrypted with session keys derived by ECDHE. Wireshark only sees "Application Data".
- **Why capture with TLS 1.2?** In TLS 1.3 the Certificate message is itself encrypted. With 1.2 you can see ServerHello, Certificate, ServerKeyExchange and ChangeCipherSpec in clear.
- **Fresh hit vs conditional vs full request?** Fresh hit: within `max-age=60`, the browser uses its copy and sends no request. Conditional: after expiry it sends `If-None-Match: "cn-cache-v1"`, and the server answers `304` with no body. Full: no validator, or the ETag changed, so `200` with the body.
- **Ports in a socket pair?** Client ephemeral port (49152–65535 on macOS) ↔ server well-known port (53/UDP, 443/TCP). Edge → backend: nginx ephemeral port ↔ 3001/3002.
- **Sequence/ack numbers?** Each side picks a random ISN; the SYN consumes 1. ACK = next byte expected. Lost segments are retransmitted after RTO or 3 duplicate ACKs. The receive window gives flow control.

## Phase 2 questions
- **DNS failure vs application failure (Ext A)?** DNS failure: the name cannot be turned into an IP, so the client never even tries TCP (dig: timeout/SERVFAIL; curl exit 6). Application failure: the name resolves and TCP/TLS to the edge work, but the edge returns 502 (curl gets an HTTP response).
- **How does the client fail over to the backup DNS?** The resolver list is ordered. When the primary's port 53 is closed, the host answers ICMP port-unreachable (or there's no reply if the host is gone), and after a short timeout the stub resolver retries the next server.
- **What does TTL do (Ext B)?** It tells every cache how many seconds it may reuse the answer. After a record change, clients keep the old IP for up to one TTL. Production practice: lower the TTL well before a migration, cut over, then raise it again.
- **Why flush?** `dscacheutil -flushcache; killall -HUP mDNSResponder` empties the OS cache, so the next lookup asks the server and sees the change immediately.
- **pf: drop vs refused (Ext C)?** Our rule drops the SYN, so the client retransmits and times out (curl exit 28). A stopped backend instead answers RST, so the client gets "connection refused" (curl exit 7) immediately. The edge's source IP is allowed. pf is stateful, so replies go back out.
- **How does nginx detect a dead backend (Ext D)?** Passively. A connect error counts as a failure; with `max_fails=1` the server is marked down for `fail_timeout=10s`, and `proxy_next_upstream` retries the same request on the other backend, so the client never sees an error. After 10 s one real request probes A again, and it rejoins if it works.
- **Remaining single point of failure?** The edge. Clients reach it by one IP; if nginx on Mac 2 dies, everything fails until DNS is changed and the TTL expires. Fixes: a floating VIP with VRRP/keepalived or CARP, multiple A records with health-checked DNS, or a managed cloud LB (which is many nodes behind one name). The backend host is also a SPOF in our 3-person setup.
- **Edge cutover (Ext E)?** The standby nginx runs the same config and the same certificate (the certificate is for the *name*, so any edge holding the key can serve it). Change the A record. New lookups go to the standby at once; clients holding the cached old answer keep using edge1 for up to 30 s. Only after that do we stop edge1 (connection draining).
- **Why not a certificate per edge IP?** TLS authenticates the hostname in SAN (`app.teamX.test`, `api.teamX.test`), not the IP, so moving the name between IPs needs no new cert.
- **Troubleshooting method (Ext F)?** Bottom-up, one layer at a time: own IP/Wi-Fi → `dig` (does the name resolve, and to an edge IP?) → `nc -z ip 443` (refused vs timeout) → `openssl s_client -verify_return_error` → `curl -v` (HTTP status) → from the edge, `curl` the backend directly. The first layer that fails is where the fault is.

## OSI / TCP-IP mapping
DNS, HTTP = Application · TLS = Session/Presentation (runs over TCP) · TCP/UDP = Transport · IP, ICMP = Network · Wi-Fi 802.11 / Ethernet framing, ARP = Link.
