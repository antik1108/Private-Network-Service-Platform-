# Private DNS Server (`dnsmasq`) Guide

This directory contains configuration templates and operation guides for the private DNS server (**Mac 1**) in the Private Network Service Platform.

---

> **Phase 2 (23 Nov 2026):** two resolvers run this config: Mac 1 (Tanmay, `10.7.6.8`, primary) and Mac 2 (Vansh, `10.7.31.150`, backup). The config is rendered from [dnsmasq.conf.template](dnsmasq.conf.template) by `scripts/render-configs.sh` and installed to `~/cn-project/dnsmasq/` by `scripts/deploy.sh`.

## Running without sudo

macOS lets an unprivileged process bind a port below 1024 **only on the wildcard address**. dnsmasq normally binds every interface address separately (`Permission denied` as a normal user), so the config uses:

```conf
port=53
bind-interfaces
listen-address=0.0.0.0
```

Start and stop with `~/cn-project/bin/cn.sh dns start|stop|restart|reload|status`. No `sudo brew services` is needed. Stop any old brew service first: `brew services stop dnsmasq`.

## 1. Configuration

Rendered config (Mac 1), see [`config/rendered/mac1/dnsmasq.conf`](../config/rendered/mac1/dnsmasq.conf):

```conf
port=53
bind-interfaces
listen-address=0.0.0.0
no-hosts
addn-hosts=/Users/<user>/cn-project/dnsmasq/teamX.hosts   # the zone
local-ttl=30                                               # TTL clients may cache (Ext B)
local=/teamX.test/                                         # never forward project names
domain-needed
bogus-priv
no-resolv
no-poll
server=10.5.7.1                                            # college DNS
server=8.8.8.8
log-queries
log-facility=/Users/<user>/cn-project/logs/dnsmasq.log
```

Zone file `teamX.hosts` (identical on both resolvers):

```text
10.7.31.150 app.teamX.test api.teamX.test
```

Changing a record live (Ext B/E): `~/cn-project/bin/cn.sh dns-record <new-ip>` rewrites the file and sends SIGHUP. dnsmasq re-reads it and clears its cache, with no restart.

## 2. Managing the Service

```bash
~/cn-project/bin/cn.sh dns start      # start (config test first)
~/cn-project/bin/cn.sh dns reload     # re-read teamX.hosts (SIGHUP)
~/cn-project/bin/cn.sh dns stop       # Extension A: stop the primary
~/cn-project/bin/cn.sh dns status
tail -f ~/cn-project/logs/dnsmasq.log # every query, with the client IP
```

### Foreground / Live Debug Mode
To observe DNS queries arriving in real time (great for live demos and debugging):
```bash
/opt/homebrew/sbin/dnsmasq -d --conf-file=$HOME/cn-project/dnsmasq/dnsmasq.conf   # foreground, Ctrl-C to stop (stop the background one first)
```

---

## 3. Verification & Testing

### Step 1: Verify Port 53 is Listening
```bash
lsof -nP -iUDP:53
```
*Expected: `dnsmasq` process listening on UDP and TCP port 53.*

### Step 2: Query the DNS Server Directly
```bash
# Query locally on Mac 1:
dig @127.0.0.1 app.teamX.test

# Query from another LAN client:
dig @10.7.6.8 app.teamX.test
```
*Expected output: Returns `10.7.31.150` with a 30s TTL in the ANSWER section.*

### Step 3: Verify Private Domain Isolation
```bash
dig @8.8.8.8 app.teamX.test
```
*Expected output: `NXDOMAIN` or no answers (proves domain exists purely on private network).*

---

## 4. macOS Client DNS Setup

For macOS clients to automatically resolve `app.teamX.test`:

1. Open **System Settings > Network > Wi-Fi > Details... > DNS**.
2. DNS servers, in this order: `10.7.6.8` (primary, Mac 1) and `10.7.31.150` (backup, Mac 2).
   `sudo scripts/phase2/client-setup.sh` does this (plus CA trust and a cache flush).
3. Remove public DNS entries (e.g., `8.8.8.8` or router IP) from the top of the list so queries aren't routed externally.
4. Flush macOS DNS cache:
   ```bash
   sudo dscacheutil -flushcache
   sudo killall -HUP mDNSResponder
   ```
5. Test standard resolution:
   ```bash
   dscacheutil -q host -a name app.teamX.test
   ```

---

## 5. Troubleshooting & Gotchas

| Issue / Symptom | Root Cause | Fix |
| --- | --- | --- |
| **`failed to create listening socket … Permission denied`** | Non-root dnsmasq binding per-interface addresses on port 53 | Use `bind-interfaces` + `listen-address=0.0.0.0` (wildcard bind is allowed unprivileged). |
| **`dig app.teamX.test` shows `SERVER: 100.100.100.100`** | Tailscale DNS overrides `/etc/resolv.conf` | Turn off "Use Tailscale DNS settings" (`tailscale set --accept-dns=false`) for the demo. |
| **`Address already in use` (Port 53)** | Another DNS process (`mDNSResponder` or leftover `dnsmasq`) is holding port 53 | Run `sudo lsof -nP -i:53` to find PID, then kill it and restart `dnsmasq`. |
| **Wireshark query not captured on `en0`** | When testing on the same machine, macOS routes traffic via `lo0` (loopback) | In Wireshark, capture on **`Loopback: lo0`** interface when querying `127.0.0.1` or local IP. |
| **`curl: (28) Failed to connect to app.teamX.test port 80: Timeout`** | DNS resolved correctly, but Nginx (Mac 2) is unreachable or not running | This is an Nginx / network issue, not DNS! Check `~/cn-project/bin/cn.sh edge status` on Mac 2 and verify Mac 2's IP. |
