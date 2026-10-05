# Private DNS Server (`dnsmasq`) Guide

This directory contains configuration templates and operation guides for the private DNS server (**Mac 1**) in the Private Network Service Platform.

---

## ⚠️ Critical Rule: Root Privileges Required

Because DNS operates on port **53** (a privileged port < 1024), **`dnsmasq` MUST be managed and run with `sudo`**.

```bash
# Correct:
sudo brew services start dnsmasq
sudo brew services restart dnsmasq
sudo brew services stop dnsmasq

# ❌ INCORRECT (running without sudo):
# brew services restart dnsmasq
# --> Will trigger: "Warning: `dnsmasq` must be run as root..." and fail to bind port 53!
```

---

## 1. Configuration Setup

1. Check current team IPs in [team/team.env](file:///Users/antikmondal/Downloads/cn-starter/team/team.env).
2. Configure `/opt/homebrew/etc/dnsmasq.conf` (based on [dnsmasq.conf.template](file:///Users/antikmondal/Downloads/cn-starter/dnsmasq/dnsmasq.conf.template)):

```conf
# /opt/homebrew/etc/dnsmasq.conf

# Port and standard options
port=53
domain-needed
bogus-priv

# Listen only on loopback and LAN interface
listen-address=127.0.0.1,10.7.7.19

# Private domain records pointing to Nginx Load Balancer (Mac 2: 10.7.17.201) with 30s TTL
host-record=app.teamX.test,10.7.17.201,30
host-record=api.teamX.test,10.7.17.201,30

# Forward non-private external queries to public DNS
no-resolv
no-poll
server=8.8.8.8
```

---

## 2. Managing the Service

### Start / Restart
```bash
# Start service
sudo brew services start dnsmasq

# Restart after config change
sudo brew services restart dnsmasq

# Check service status
sudo brew services list | grep dnsmasq
```

### Foreground / Live Debug Mode
To observe DNS queries arriving in real time (great for live demos and debugging):
```bash
sudo /opt/homebrew/sbin/dnsmasq -d
```

---

## 3. Verification & Testing

### Step 1: Verify Port 53 is Listening
```bash
sudo lsof -nP -iUDP:53 -iTCP:53 -sTCP:LISTEN
```
*Expected: `dnsmasq` process listening on UDP and TCP port 53.*

### Step 2: Query the DNS Server Directly
```bash
# Query locally on Mac 1:
dig @127.0.0.1 app.teamX.test

# Query from another LAN client:
dig @10.7.7.19 app.teamX.test
```
*Expected output: Returns `10.7.17.201` with a 30s TTL in the ANSWER section.*

### Step 3: Verify Private Domain Isolation
```bash
dig @8.8.8.8 app.teamX.test
```
*Expected output: `NXDOMAIN` or no answers (proves domain exists purely on private network).*

---

## 4. macOS Client DNS Setup

For macOS clients to automatically resolve `app.teamX.test`:

1. Open **System Settings > Network > Wi-Fi > Details... > DNS**.
2. Add DNS Server:
   - On Mac 1 itself: `127.0.0.1`
   - On other LAN machines: `10.7.7.19` (Mac 1 IP)
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
| **`Warning: dnsmasq must be run as root`** | Executed `brew services` without `sudo` | Always use `sudo brew services restart dnsmasq`. |
| **`Address already in use` (Port 53)** | Another DNS process (`mDNSResponder` or leftover `dnsmasq`) is holding port 53 | Run `sudo lsof -nP -i:53` to find PID, then kill it and restart `dnsmasq`. |
| **Wireshark query not captured on `en0`** | When testing on the same machine, macOS routes traffic via `lo0` (loopback) | In Wireshark, capture on **`Loopback: lo0`** interface when querying `127.0.0.1` or local IP. |
| **`curl: (28) Failed to connect to app.teamX.test port 80: Timeout`** | DNS resolved correctly, but Nginx (Mac 2) is unreachable or not running | This is an Nginx / network issue, not DNS! Check `sudo brew services list` on Mac 2 and verify Mac 2's IP. |
