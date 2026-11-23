# Phase 2 — The Easy Guide

> **You don't need to remember IPs or long commands.** Remember **names** and **one command**: `scripts/demo.sh`.
> It explains each step in plain English, runs the commands for you, tells you what to point at and what to say, and waits for Enter.

All commands below are typed on **Antik's Mac**, inside the project folder:
```bash
cd ~/Downloads/cn-starter
```

---

## 1. Remember NAMES, not IPs

| Say this… | …it means this IP | Job | Everyday analogy |
| --- | --- | --- | --- |
| **Tanmay's Mac** | `10.7.6.8` | **DNS #1** | The phone book |
| **Vansh's Mac** | `10.7.31.150` | **Front door** (nginx) + **DNS #2** | Reception desk + spare phone book |
| **Antik's Mac** | `10.7.22.168` | **Backend A** + **Backend B** + **spare front door** + **firewall** | The back office (2 clerks), a spare reception desk, the security guard |

**Golden rule:** `app.teamX.test` → **Vansh's Mac** (the front door). Always. Except during the Extension E demo, when we move it to Antik's Mac on purpose.

If you ever get confused: `scripts/demo.sh who` prints this table, plus a live status of every Mac.

---

## 2. The only commands you need

| Type this | What happens | Password? |
| --- | --- | --- |
| `scripts/demo.sh who` | Who is who + is everything running | – |
| `scripts/demo.sh check` | Is the website healthy right now? | – |
| `scripts/demo.sh A` | Extension A: kill DNS #1, show the backup takes over | – |
| `scripts/demo.sh B` | Extension B: change the DNS record, watch the 30 s timer, flush | yes (once) |
| `scripts/demo.sh C` | Extension C: firewall on → Tanmay blocked, Vansh allowed → firewall off | yes |
| `scripts/demo.sh D` | Extension D: kill Backend A, service keeps working, bring it back | – |
| `scripts/demo.sh E` | Extension E: move the website to the spare front door | – |
| `scripts/demo.sh F` | Extension F: check every layer, name the broken one | – |
| `scripts/demo.sh break` | Practice: secretly break something | – |
| `scripts/demo.sh answer` | Practice: reveal what was broken | – |
| `scripts/demo.sh fix` | **Repair everything** (use it any time something looks wrong) | – |

---

## 3. Before the faculty arrives (5 minutes)

1. All three Macs on the **college Wi-Fi**.
2. Tailscale DNS **off** (Tailscale menu → untick "Use Tailscale DNS settings").
3. Run:
   ```bash
   scripts/demo.sh who
   scripts/demo.sh check
   ```
   You want: every service **UP**, requests **200** with **A and B taking turns**, and **"All layers healthy"**.
4. If an IP changed: tell Antik, then update `team/team.env` → `scripts/deploy.sh` → `sudo scripts/phase2/client-setup.sh`.
5. If anything looks wrong: `scripts/demo.sh fix`.

---

## 4. Presenting Phase 2 — the running order (about 12 minutes)

Open with one sentence:
> "In Phase 1 we built it. In Phase 2 we made it **survive failures** and made faults **easy to find**. The brief has 6 extensions. Here they are, live."

### Extension A — Backup DNS (Tanmay presents) · `scripts/demo.sh A`
- **Idea:** two phone books. If Tanmay's DNS dies, every Mac asks Vansh's.
- **You'll see:** both DNS servers give the same answer. Tanmay's DNS stops ("connection timed out"). Then `SERVER: 10.7.31.150`, and the website still returns **200**.
- **Say:** "DNS #1 is dead, but clients automatically used the backup. Users noticed nothing."
- **Key difference the brief asks for:**
  - **DNS failure** = the name can't be found, so nothing even starts.
  - **Application failure** = the name is found and the connection works, but the app is down → **502**.

### Extension B — TTL, the DNS memory timer (Tanmay presents) · `scripts/demo.sh B`
- **Idea:** every DNS answer says "remember me for **30 seconds**". Change the record, and Macs keep the **old** answer until the timer runs out.
- **You'll see:** a countdown table. The **left column (this Mac)** stays OLD for ~30 s while the **right column (DNS server)** is already NEW. Then the left flips.
- **Then flush:** `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` → the change is **instant**.
- **Say:** "This is why companies lower the TTL before moving a server: the change only reaches everyone after one TTL."

### Extension C — Firewall (Antik presents) · `scripts/demo.sh C`
- **Idea:** a security guard on Antik's Mac. **Only Vansh's front door** may talk to the backends.
- **You'll see:**
  - **Before:** Tanmay reaches the backend directly (JSON).
  - **Firewall on:** `APPLIED: 5 rules`.
  - **After:** Tanmay gets `exit=28` (timeout = blocked), Vansh gets `200`, and the website through the front door still gives `200`.
  - **Firewall off:** rollback.
- **Say:** "exit 28 = **timeout**: the firewall silently drops packets. A dead server would say **refused** instantly (exit 7). That's how you tell them apart. We keep a rollback copy, as required."
- **Why on Antik's Mac?** A firewall runs on the machine it protects, and the backends live there.

### Extension D — A backend dies (Vansh presents) · `scripts/demo.sh D`
- **Idea:** the front door notices a dead backend and sends everyone to the healthy one.
- **You'll see:** A and B alternate → Backend A stopped → **all 200, all B** → nginx log says `Connection refused` + `temporarily disabled` → A restarted → after 10 s, A and B alternate again.
- **Say:** "nginx tried A, it refused, so nginx retried the same request on B. The user never saw an error. A is benched for 10 seconds, then tried again."
- **Single point of failure (the brief asks this):** "The front door itself: one nginx on Vansh's Mac. To remove it you need two front doors sharing one floating IP (VRRP/keepalived), or a cloud load balancer. Extension E shows our manual version."

### Extension E — Switch to the spare front door (Vansh/Antik present) · `scripts/demo.sh E`
- **Idea:** Antik's Mac runs a **second nginx** with the same settings and certificate. Change the DNS record, and traffic moves there.
- **You'll see:**
  - Tanmay (a fresh lookup) goes to the spare door **immediately**: `x-edge: edge2-mac3`.
  - This Mac (old answer remembered) stays on `edge1-mac2` for ~30 s, then flips to `edge2-mac3`.
  - Then it's put back.
- **Say:** "New lookups move at once; cached clients move when their 30-second TTL ends. So you keep the old server running for one TTL after a switch."
- **Why does the same certificate work on both?** "TLS checks the **name** `app.teamX.test`, not the IP."

### Extension F — Faculty breaks something (everyone) · `scripts/demo.sh F`
- **Idea:** check from the **bottom up** and stop at the first broken layer.
- **Say out loud while it runs:** "First my own network… then DNS… can I reach the IP… is port 443 open… is the certificate valid… what HTTP code… can the front door reach the backends."
- **Read the last line** `>>> FIRST FAILING LAYER: …` and the `likely cause`. Then fix it (`scripts/demo.sh fix` repairs everything).

| The tool says | It means | Fix |
| --- | --- | --- |
| **L2 DNS** | Phone book problem (DNS down / wrong record / client DNS setting) | start DNS / correct the record |
| **L4 refused** | Front door not listening (nginx stopped, wrong port) | start nginx |
| **L4 timeout** | Firewall dropping packets | roll back / fix the firewall |
| **L5 TLS** | Wrong or untrusted certificate | reinstall the right certificate |
| **502 / L7** | Front door OK, backends unreachable | start backends / check firewall / upstream config |

---

## 5. Wireshark for Phase 2 (optional but impressive)

Open the file in Wireshark, type the filter in the top bar, press Enter.

| Show this | File (`evidence/phase2/captures/`) | Filter | Point at |
| --- | --- | --- | --- |
| **Backup DNS** (Ext A) | `extA-dns-failover.pcapng` | `dns or icmp` | A query to Tanmay → **"Destination unreachable (Port unreachable)"** (DNS #1 is dead) → Vansh's answer `10.7.31.150` |
| **Firewall** (Ext C) | `extC-isolation-backend-side.pcapng` | `tcp.port == 3001` | Tanmay (`10.7.6.8`) sends **SYN** ~10 times with **no reply** (dropped). Vansh (`10.7.31.150`) sends SYN → gets **SYN-ACK** → real traffic |
| **Whole journey** (Phase 1) | `phase1-full-flow-lan.pcapng` | `dns`, then `tcp.flags.syn==1`, then `tls.handshake` | DNS question/answer → TCP handshake → TLS hello + certificate |

Line for the faculty: *"Wireshark proves it at the packet level: the firewall never answers Tanmay, while Vansh gets a normal handshake."*

---

## 6. Practice routine (do this 5–10 times)

```bash
scripts/demo.sh break      # something is secretly broken
scripts/demo.sh F          # find it - say each layer out loud
scripts/demo.sh answer     # were you right?
scripts/demo.sh fix        # repair everything
```
Faults it can inject: DNS #1 down, both DNS down, wrong DNS record, nginx down, Backend A down, both backends down, wrong certificate.
Tip: for DNS faults, wait ~30 s before running F. Your Mac may still remember the old answer, which is itself a good TTL example to mention.

---

## 7. Questions the faculty will probably ask (with short answers)

**Extension A — Backup DNS**
- *How does the client know about the backup?* → Its DNS list has both servers (Network settings: `10.7.6.8, 10.7.31.150`).
- *How fast does it switch?* → Immediately. macOS asks both, and a dead server returns "port unreachable" (seen in Wireshark).
- *DNS failure vs application failure?* → DNS failure: the name can't be resolved, so no connection happens. App failure: DNS + TCP + TLS work, and the front door returns 502.
- *Do both servers have the same data?* → Yes. We update both with the same command (`dns-record`). A real setup would use zone transfer (AXFR).

**Extension B — TTL**
- *What is TTL?* → How many seconds a DNS answer may be cached. Ours is 30 s.
- *Why didn't the client change immediately?* → It was still using its cached answer until the 30 s ran out.
- *How do you force it?* → Flush the cache: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`.
- *Real-world use?* → Lower the TTL before a migration, switch, wait one TTL, then switch off the old server.
- *Why not TTL 0?* → Every request would hit DNS: slower, and a heavy load on the DNS server.

**Extension C — Firewall**
- *Which machine runs it and why?* → Antik's Mac, because the backends live there and a firewall protects its own machine.
- *What tool?* → macOS **pf** (packet filter), loaded as an anchor, so the system's own rules aren't touched.
- *Timeout vs refused?* → Timeout (exit 28) = firewall dropped it. Refused (exit 7) = nothing listening.
- *How do you undo it?* → `firewall.sh rollback`. We saved the original state before applying.
- *Cloud equivalent?* → A security group allowing the app port only from the load balancer.

**Extension D — HA failover**
- *How does nginx detect a dead backend?* → Passively: a failed connection marks it down (`max_fails=1`) for 10 s (`fail_timeout=10s`).
- *Why did no request fail?* → `proxy_next_upstream` retries the same request on the other backend.
- *How does A come back?* → After 10 s nginx tries it again; if it answers, it rejoins.
- *What is still a single point of failure?* → The front door (one nginx), and Antik's laptop (both backends). Fix: floating IP / second laptop / cloud LB.

**Extension E — Edge cutover**
- *How did traffic move?* → By changing one DNS record to the spare front door's IP.
- *Why did some clients still hit the old door?* → They had cached the old answer (TTL).
- *Why does the same certificate work?* → TLS validates the hostname, not the IP.
- *When can you shut down the old door?* → After at least one TTL, once all caches have expired.

**Extension F — Troubleshooting**
- *What is your method?* → Bottom-up: network → DNS → IP → TCP port → TLS → HTTP → backend. Stop at the first failure.
- *How do you know it's DNS vs network?* → If `dig` fails but `ping` to the IP works, it's DNS.
- *How do you know it's the backend and not nginx?* → TLS works, and nginx answers with 502 → nginx is alive, the backends aren't.

**Whole system (anyone may be asked)**
- *Walk me through one request.* → DNS question to Tanmay → answer: Vansh → TCP handshake to Vansh port 443 → TLS handshake (certificate check) → encrypted HTTP request → nginx forwards to A or B on Antik → answer comes back with `X-Backend`.
- *Why does the client never see the backend IPs?* → It only ever talks to the front door.
- *What changed from Phase 1?* → Backup DNS, 30 s TTL, firewall, automatic failover, spare front door, troubleshooting tool, one config file for all IPs.

---

## 8. If something goes wrong during the demo

| You see | Do this |
| --- | --- |
| Anything weird | `scripts/demo.sh fix`, then `scripts/demo.sh check` |
| `502` everywhere | Is Antik's Mac on the college Wi-Fi? → `scripts/demo.sh fix` |
| `front-door=edge2` when you didn't expect it | The Mac remembers an old DNS answer: wait 30 s |
| `dig` says `SERVER: 100.100.100.100` | Tailscale DNS is on: turn it off |
| Certificate error on one Mac | `sudo scripts/phase2/client-setup.sh` on that Mac |

Calm-down line for the viva: *"Let me check it layer by layer."* Then run `scripts/demo.sh F`.
