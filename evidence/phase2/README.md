# Phase 2 Evidence Index

Everything here was produced by the scripts in `scripts/phase2/` against the live 3-Mac system on **23 Nov 2026**. Each log contains the exact commands and their real output. Re-run any of them with `scripts/phase2/run-tests.sh <name>`.

## Logs (`logs/`)

| File | Covers | Key lines |
| --- | --- | --- |
| [p1.log](logs/p1.log) | Phase 1 regression: Task A inventory + ping matrix, B both resolvers, C backends from the edge, D/E HTTPS by name with verified cert and HTTP/2, round robin, F `Cache-Control`/`ETag`/`304`, 80→443 redirect | `SSL certificate verify ok`, `x-backend` alternating, `HTTP/2 304` |
| [p1fail.log](logs/p1fail.log) | Phase 1 §6.3 failures: wrong DNS server, wrong record IP, one backend down, both down (502), wrong port | F3 all 200 via B; F4 `HTTP/2 502` with TLS still verifying; F5 exit 7 refused |
| [extA.log](logs/extA.log) | Backup DNS: primary stopped, client keeps resolving via Mac 2; DNS failure vs app failure | `PASS: client resolves with primary down`, `HTTP 502` with DNS still working |
| [extB.log](logs/extB.log) | TTL 30 s, record change, client keeps the cached answer, then switches; manual flush gives an immediate change | `t=+01s client=10.7.31.150 server=10.7.22.168` … `t=+41s client=10.7.22.168`; after flush `10.7.31.150` |
| [extC.log](logs/extC.log) | pf isolation: edge → backend 200, client → backend timeout (exit 28), client → edge 200; rollback restores access | both PASS + rollback |
| [extD.log](logs/extD.log) | Backend A stopped: 8/8 requests served by B, nginx log shows the retry `upstream_status=502, 200`, A rejoins after 10 s | `PASS: all 8 requests succeeded via B` |
| [extE.log](logs/extE.log) | Standby edge + DNS cutover: Mac 1's new lookup → edge2 at once; cached Mac 3/4 stays on edge1 until +31 s, edge2 at +35 s | `PASS: client A moved to edge2 after TTL` |
| [extF-drills.log](logs/extF-drills.log) | Six injected faults (wrong record, both DNS down, nginx down, wrong upstream ports, wrong cert, both backends down), each diagnosed by `scripts/diagnose.sh`; final check healthy | `>>> FIRST FAILING LAYER: …` |

## Packet captures (`captures/`)

Open in Wireshark. Each `.txt` next to a capture is a tshark summary with frame numbers.

| Capture | Where captured | What to show |
| --- | --- | --- |
| [phase1-full-flow-lan.pcapng](captures/phase1-full-flow-lan.pcapng) ([summary](captures/phase1-full-flow-lan.txt)) | Client Mac 3/4 en0 | **DNS** frames 1–4: queries from ephemeral ports to 10.7.6.8:53 and 10.7.31.150:53, answer `10.7.31.150` TTL 30. **TCP** frames 5–7: SYN/SYN-ACK/ACK 10.7.22.168:53151 → 10.7.31.150:443. **TLS 1.2** frame 8 ClientHello (SNI app.teamx.test), 11 ServerHello+Certificate (SAN app/api.teamX.test), 12 ServerKeyExchange, 14/16 ChangeCipherSpec, then encrypted Application Data. **Edge → backend** frames 24/28 (SYN to :3001) and 72/74 (:3002), visible because the backends run on this Mac. Stream 2 is a TLS 1.3 + HTTP/2 request for comparison (certificate hidden). |
| [extA-dns-failover.pcapng](captures/extA-dns-failover.pcapng) ([summary](captures/extA-dns-failover.txt)) | Client en0 | Primary stopped: query to 10.7.6.8 → **ICMP port unreachable** (frame 8), backup 10.7.31.150 answers (frame 9). The macOS resolver sends to both servers in parallel and takes the first good answer. |
| [extC-isolation-backend-side.pcapng](captures/extC-isolation-backend-side.pcapng) ([summary](captures/extC-isolation-backend-side.txt)) | Backend Mac en0 with pf on | Client 10.7.6.8 → :3001: **10 SYN retransmissions, no reply** (dropped by pf). Edge 10.7.31.150 → :3001: SYN, SYN-ACK, full HTTP exchange. |

## Config snapshot

Rendered configs exactly as deployed: [`config/rendered/`](../../config/rendered). dnsmasq for Mac 1 and Mac 2, nginx for edge1 and edge2, pf rules for the backend Mac.
