> **Historical Phase 1 record (Sept-Oct 2026).** Addresses here are the DHCP leases at that time (e.g. DNS+backends on 10.7.7.19, edge on 10.7.10.162 / 10.7.17.201). Current addresses: [team/team.env](../../../team/team.env). Phase 2 evidence: [evidence/phase2/](../../phase2).

# Phase 1 video recording package

This package contains a voiceover-ready subtitle track and a verified recording outline for a 4:25 screen demonstration. The MP4 has not been created: macOS screen capture failed in this session (`screencapture -i -v` returned `dispatch_source_create returned NULL`), and QuickTime could not leave its open-file dialog. I have not substituted a slide deck or a simulated terminal video.

## Verified live state on 5 October 2026

- Private DNS answered `app.teamX.test` as `10.7.17.201` with TTL 0. Public DNS returned no answer (NXDOMAIN in the full query).
- `ping` to `10.7.17.201` succeeded (2/2 replies).
- `curl -v https://app.teamX.test/api/status` resolved the name, then timed out connecting to TCP port 443. The edge host is reachable by ICMP but HTTPS is unavailable at the time of this run.
- Direct requests to Backend A (`:3001`) and Backend B (`:3002`) returned HTTP 200 with their respective `X-Backend` headers.
- Backend A was stopped for the requested fault check: its port refused the request while Backend B continued returning HTTP 200. Backend A was restarted with `./scripts/run-backend.sh A` and verified healthy afterward.
- Backend A returned `ETag: "cn-cache-v1"` and `Cache-Control: public, max-age=60`; a conditional request returned HTTP 304.

## Wireshark evidence

The fresh capture is [phase1-live-loopback-20261005.pcapng](../phase1-live-loopback-20261005.pcapng). Wireshark captured 387 packets with no drops on `lo0`. Apply this display filter to focus on project packets:

```text
dns || tcp.port == 3001 || tcp.port == 3002
```

Frames 292-294 show the live TCP three-way handshake to Backend A, frames 260-262 show the handshake to Backend B, and frames 342-343 show the DNS query and answer. These are loopback/backend exchanges. They do not show the unavailable edge's TLS handshake. The existing `screenshots/tls-stream-overview.png` is archived evidence from an earlier run; label it as such if shown. Do not present it as a capture from this session or claim a current HTTPS success.

## Recording outline

Follow the SRT timing. Use live terminal output for the verified checks, then Wireshark with the filter above. The network state needs to be repaired on the Nginx edge before recording a successful end-to-end HTTPS/load-balancing demonstration. The current live test is a useful TCP failure diagnosis, but it cannot prove Nginx failover.

Commands used in the live checks:

```bash
ping -c 2 10.7.17.201
dig @10.7.7.19 app.teamX.test
dig @8.8.8.8 app.teamX.test
curl -v https://app.teamX.test/api/status
curl -i http://10.7.7.19:3001/api/status
curl -i http://10.7.7.19:3002/api/status
curl -I http://10.7.7.19:3001/api/cache
curl -i -H 'If-None-Match: "cn-cache-v1"' http://10.7.7.19:3001/api/cache
```
