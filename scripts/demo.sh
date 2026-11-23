#!/bin/bash
# demo.sh - guided, plain-English Phase 2 presenter. Run on Antik's Mac from the project folder.
#
#   scripts/demo.sh who     who is who (names, IPs, roles) + live status
#   scripts/demo.sh check   is everything healthy?
#   scripts/demo.sh A       Ext A  backup DNS
#   scripts/demo.sh B       Ext B  TTL (DNS cache timer)            [asks your password once]
#   scripts/demo.sh C       Ext C  firewall around the backends      [asks your password]
#   scripts/demo.sh D       Ext D  a backend dies, service survives
#   scripts/demo.sh E       Ext E  switch to the spare front door
#   scripts/demo.sh F       Ext F  find a fault layer by layer
#   scripts/demo.sh break   practice: inject a RANDOM hidden fault
#   scripts/demo.sh fix     put everything back to normal (use any time something looks wrong)
#
# NOPAUSE=1 scripts/demo.sh A   runs without waiting for Enter.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/team/team.env"; source "$ROOT/scripts/lib/remote.sh"
CN='~/cn-project/bin/cn.sh'
APP="app.$TEAM_DOMAIN"
STATE="$ROOT/config/.demo-fault"

B=$'\e[1m'; C=$'\e[36m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; M=$'\e[35m'; N=$'\e[0m'
name_of() { case "$1" in "$MAC1_IP") echo "Tanmay's Mac (DNS #1)";; "$MAC2_IP") echo "Vansh's Mac (front door / DNS #2)";; "$MAC3_IP") echo "Antik's Mac (backends / spare front door)";; *) echo "$1";; esac; }

title() { echo; echo "${B}${M}════════════════════════════════════════════════════════════${N}"; echo "${B}${M}  $*${N}"; echo "${B}${M}════════════════════════════════════════════════════════════${N}"; }
idea()  { echo "${B}IDEA:${N} $*"; }
step()  { echo; echo "${B}${C}▶ $*${N}"; }
say()   { echo "${G}🗣  SAY:${N} $*"; }
look()  { echo "${Y}👀 LOOK AT:${N} $*"; }
pause() { [ "${NOPAUSE:-0}" = 1 ] && return; printf "\n   ${B}[press Enter to continue]${N}"; read -r _; }
# show + run a command on this Mac
run()   { echo "   ${B}\$ $*${N}"; eval "$*" 2>&1 | sed 's/^/     /'; }
# show + run a command on another Mac (over SSH), labelled with the person's name
on()    { local n="$1"; shift; local who; who="$(name_of "$(node_ip "$n")")"
          echo "   ${B}[on $who]\$ $*${N}"; run_on "$n" "$*" 2>&1 | sed 's/^/     /'; }
# one HTTPS request, printed as "200  backend=A  front-door=edge1-mac2"
hit()   { curl -s -o /dev/null --max-time 6 -D - "https://$APP/api/status" 2>/dev/null \
          | awk '{l=tolower($0)} NR==1{c=$2} l~/^x-backend/{b=$2} l~/^x-edge/{e=$2} END{printf "%s  backend=%s  front-door=%s\n", (c?c:"FAILED"), b, e}' | tr -d '\r'; }
hits()  { local i; for i in $(seq 1 "${1:-6}"); do printf '     request %s: ' "$i"; hit; done; }
sysip() { dscacheutil -q host -a name "$APP" | awk '/ip_address/{print $2}' | head -1; }
# wait until this Mac's cached DNS answer points at the normal front door again
wait_normal() { local i=0; while [ "$(sysip)" != "$APP_RECORD_IP" ] && [ $i -lt 12 ]; do
                  [ $i = 0 ] && echo "     (this Mac still remembers an old DNS answer - waiting for its 30 s TTL...)"; sleep 4; i=$((i+1)); done; }

# ------------------------------------------------------------------ who / check
who() {
  title "WHO IS WHO  (remember the NAMES, the IPs are just their addresses)"
  cat <<EOF

  ${B}Tanmay's Mac${N}  = ${B}$MAC1_IP${N}   → ${B}DNS #1${N}  (the phone book: turns app.teamX.test into an address)
  ${B}Vansh's Mac${N}   = ${B}$MAC2_IP${N}  → ${B}FRONT DOOR${N} (nginx: HTTPS + load balancer)  + ${B}DNS #2${N} (spare phone book)
  ${B}Antik's Mac${N}   = ${B}$MAC3_IP${N}  → ${B}BACKEND A${N} (port 3001) + ${B}BACKEND B${N} (port 3002)
                                   + ${B}SPARE FRONT DOOR${N} (nginx, used in Ext E) + ${B}FIREWALL${N} (Ext C)

  app.teamX.test normally points to → ${B}Vansh's Mac${N} ($APP_RECORD_IP), the front door.

  Journey of one request:
    you ──"where is app.teamX.test?"──► Tanmay (DNS)  ──"at $APP_RECORD_IP"──► you
    you ──HTTPS──► Vansh (front door) ──► Antik (backend A or B) ──► back to you
EOF
  step "Live status of every Mac"
  on mac1 "$CN status | tail -n +2"
  on mac2 "$CN status | tail -n +2"
  on mac3 "$CN status | tail -n +2"
}

check() {
  title "HEALTH CHECK - is everything working?"
  step "1) Can this Mac find app.teamX.test?  (DNS)"
  run "dig $APP +short"
  step "2) Does the website work over HTTPS, with load balancing?"
  hits 4
  step "3) Layer-by-layer check"
  "$ROOT/scripts/diagnose.sh" 2>&1 | grep -E '>>>' | sed 's/^/     /'
  say "If you see 200 with backend A and B taking turns, and 'All layers healthy', we're ready."
}

# ------------------------------------------------------------------ Extension A
ext_A() {
  title "EXTENSION A — BACKUP DNS  (spare phone book)"
  idea "Every Mac is told about TWO DNS servers: Tanmay's (#1) and Vansh's (#2). If #1 dies, Macs ask #2."
  step "Both phone books give the same answer"
  run "dig @$DNS1_IP $APP +short    # ask Tanmay"
  run "dig @$DNS2_IP $APP +short    # ask Vansh"
  run "networksetup -getdnsservers Wi-Fi    # this Mac knows both servers"
  say "Both DNS servers hold the same record. Our Macs list both of them."
  pause
  step "BREAK IT: stop DNS #1 on Tanmay's Mac"
  on mac1 "$CN dns stop"
  run "dig @$DNS1_IP $APP +time=2 +tries=1 | grep -E 'timed out|status'"
  look "'connection timed out': Tanmay's phone book is gone."
  pause
  step "The website STILL works, because this Mac falls back to DNS #2 (Vansh)"
  echo "     (waiting ${DNS_TTL}s so this Mac forgets its cached answer and must really ask again...)"; sleep $((DNS_TTL + 3))
  run "dig $APP +noall +answer +stats | grep -E 'IN|SERVER'"
  hits 2
  look "SERVER is now $DNS2_IP (Vansh), and requests still return 200."
  say "DNS #1 is down, but clients automatically used the backup, so users noticed nothing."
  pause
  step "DNS failure vs application failure (the brief asks you to explain this)"
  say "DNS failure = the NAME can't be found, so nothing even starts."
  say "Application failure = the name IS found and the connection works, but the app is down → the front door says 502."
  step "FIX IT: start DNS #1 again"
  on mac1 "$CN dns start"
  run "dig $APP +short"
}

# ------------------------------------------------------------------ Extension B
ext_B() {
  title "EXTENSION B — TTL  (how long Macs remember a DNS answer)"
  idea "Every DNS answer says 'remember me for 30 s' (the TTL). If we change the record, Macs keep the OLD answer until their 30 s timer runs out."
  sudo -v || { echo "This demo needs your Mac password for the cache flush."; return 1; }
  step "The record and its timer"
  run "dig @$DNS1_IP $APP +noall +answer"
  look "the number 30 in that line = TTL in seconds. The IP is Vansh's front door."
  run "dscacheutil -q host -a name $APP | grep ip_address    # this Mac now REMEMBERS it"
  pause
  step "CHANGE the record → Antik's Mac ($EDGE2_IP) on BOTH DNS servers"
  on mac1 "$CN dns-record $EDGE2_IP"; on mac2 "$CN dns-record $EDGE2_IP"
  run "dig @$DNS1_IP $APP +short    # the server changed IMMEDIATELY"
  pause
  step "But this Mac still uses the OLD answer until its 30 s timer expires (checking every 5 s)"
  local t0 i ans; t0=$(date +%s)
  for i in $(seq 1 12); do
    ans="$(sysip)"; printf '     after %2ss  this Mac uses: %-14s  DNS server says: %s\n' $(( $(date +%s)-t0 )) "$ans" "$(dig @$DNS1_IP $APP +short)"
    [ "$ans" = "$EDGE2_IP" ] && break; sleep 5
  done
  look "the left column stays OLD for ~30 s, then flips to the NEW IP."
  say "This is why companies lower the TTL before moving a server: the change only reaches everyone after one TTL."
  pause
  step "Change it BACK, then FLUSH the cache by hand → the change is instant"
  on mac1 "$CN dns-record $APP_RECORD_IP"; on mac2 "$CN dns-record $APP_RECORD_IP"
  run "dscacheutil -q host -a name $APP | grep ip_address    # still remembers the other one"
  run "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder    # forget everything"
  run "dscacheutil -q host -a name $APP | grep ip_address    # back to Vansh immediately"
  say "Flushing makes this Mac forget its cached answers, so it asks the server again right away."
}

# ------------------------------------------------------------------ Extension C
ext_C() {
  title "EXTENSION C — FIREWALL  (security guard in front of the backends)"
  idea "Only Vansh's front door may talk to the backends on Antik's Mac. Everyone else must go through the front door."
  step "BEFORE: no firewall. Tanmay can reach backend A directly (bypassing the front door)"
  on mac1 "curl -s -m 4 http://$BACKEND_A/api/status; echo; echo exit=\$?"
  say "Without a firewall anyone on the Wi-Fi could skip HTTPS and the load balancer."
  pause
  step "Turn the firewall ON (on Antik's Mac, because the backends live here; needs your password)"
  run "sudo $ROOT/scripts/phase2/firewall.sh apply 2>&1 | grep -E 'APPLIED|ERROR|pass|block'"
  look "'pass … from $EDGE1_IP' = Vansh allowed. 'block drop' = everyone else dropped."
  pause
  step "AFTER: Tanmay is blocked (expect a 4 s wait, then exit=28 = timeout)"
  on mac1 "curl -s -m 4 http://$BACKEND_A/api/status; echo exit=\$?"
  step "Vansh's front door is still allowed in (expect 200)"
  on mac2 "curl -s -o /dev/null -w 'front door → backend: %{http_code}\n' http://$BACKEND_A/api/status"
  step "And users going through the front door still get the website"
  on mac1 "curl -s -o /dev/null -w 'Tanmay via front door: %{http_code}\n' https://$APP/api/status"
  say "exit=28 means TIMEOUT: the firewall silently drops the packets. A stopped server would answer 'refused' instantly (exit 7). That's how you tell a firewall from a dead service."
  pause
  step "Turn the firewall OFF again (rollback, as the brief requires)"
  run "sudo $ROOT/scripts/phase2/firewall.sh rollback 2>&1 | head -1"
}

# ------------------------------------------------------------------ Extension D
ext_D() {
  title "EXTENSION D — A BACKEND DIES, THE SERVICE SURVIVES"
  idea "The front door (nginx) notices a dead backend and sends everyone to the healthy one."
  step "Normal: A and B take turns (round robin)"
  hits 4
  pause
  step "BREAK IT: stop Backend A on Antik's Mac"
  run "~/cn-project/bin/cn.sh backend stop A"
  hits 6
  look "all 200, all backend=B. No errors for the user."
  on mac2 "grep -E 'refused|disabled' ~/cn-project/logs/nginx-error.log | tail -2 | cut -c1-150"
  say "nginx tried A, got 'connection refused', retried the SAME request on B, and marked A as down for 10 seconds."
  pause
  step "FIX IT: start Backend A; after 10 s nginx tries it again"
  run "~/cn-project/bin/cn.sh backend start A"
  echo "     (waiting 11 s...)"; sleep 11
  hits 4
  look "A and B take turns again."
  say "Still a single point of failure: the front door itself (one nginx on Vansh's Mac). Fix = a second front door with a shared/floating IP, or a cloud load balancer. Extension E shows our manual version."
}

# ------------------------------------------------------------------ Extension E
ext_E() {
  title "EXTENSION E — SWITCH TO THE SPARE FRONT DOOR (DNS cutover)"
  idea "Antik's Mac runs a SECOND nginx with the same config + certificate. We move traffic there just by changing the DNS record."
  step "Spare front door is ready (asked directly)"
  run "curl -s --resolve $APP:443:$EDGE2_IP https://$APP/edge-health"
  step "Right now this Mac uses the MAIN front door (front-door=edge1-mac2)"
  local w=0; until hit | grep -q edge1; do w=$((w+1)); [ $w -gt 15 ] && break; sleep 4; done
  hits 1
  pause
  step "CUTOVER: point app.teamX.test at Antik's Mac ($EDGE2_IP) on both DNS servers"
  on mac1 "$CN dns-record $EDGE2_IP"; on mac2 "$CN dns-record $EDGE2_IP"
  step "A Mac doing a FRESH lookup (Tanmay) goes to the spare door IMMEDIATELY"
  on mac1 "curl -s -D - -o /dev/null https://$APP/api/status | grep -i x-edge"
  step "This Mac had the old answer cached → keeps using the OLD door until its 30 s TTL runs out"
  local t0 r i; t0=$(date +%s)
  for i in $(seq 1 12); do r="$(hit)"; printf '     after %2ss: %s\n' $(( $(date +%s)-t0 )) "$r"; [[ "$r" == *edge2* ]] && break; sleep 4; done
  look "front-door changes from edge1-mac2 to edge2-mac3 after ~30 s."
  say "New lookups move at once; cached clients move when their TTL expires. That's why you keep the old server running for one TTL after a cutover."
  pause
  step "Put it back: record → Vansh's front door"
  on mac1 "$CN dns-record $EDGE1_IP"; on mac2 "$CN dns-record $EDGE1_IP"
  wait_normal; hits 1
  say "The same certificate works on both doors because TLS checks the NAME (app.teamX.test), not the IP."
}

# ------------------------------------------------------------------ Extension F
ext_F() {
  title "EXTENSION F — FIND THE FAULT, LAYER BY LAYER"
  idea "Check from the bottom up: my network → DNS → can I reach the IP → is the port open → TLS → HTTP → backends. The FIRST failing layer is the problem."
  run "$ROOT/scripts/diagnose.sh"
  cat <<EOF

  ${B}How to read it:${N}
    L2 DNS fails          → a DNS server is down, or the record/client DNS setting is wrong
    L4 refused (fast)     → nginx stopped / wrong port
    L4 timeout (slow)     → a firewall is dropping packets
    L5 TLS fails          → wrong or untrusted certificate
    HTTP 502 / L7         → front door is fine, the BACKENDS are not reachable
EOF
  say "I always check DNS first, then TCP, then TLS, then the application, and I stop at the first layer that fails."
}

# ------------------------------------------------------------------ break / fix practice
faults=(dns1-down both-dns-down wrong-record nginx-down backend-a-down both-backends-down wrong-cert)
brk() {
  local f="${1:-${faults[$((RANDOM % ${#faults[@]}))]}}"
  wait_normal
  case "$f" in
    dns1-down)          run_on mac1 "$CN dns stop" ;;
    both-dns-down)      run_on mac1 "$CN dns stop"; run_on mac2 "$CN dns stop" ;;
    wrong-record)       run_on mac1 "$CN dns-record $MAC1_IP"; run_on mac2 "$CN dns-record $MAC1_IP" ;;
    nginx-down)         run_on mac2 "$CN edge stop" ;;
    backend-a-down)     run_on mac3 "$CN backend stop A" ;;
    both-backends-down) run_on mac3 "$CN backend stop" ;;
    wrong-cert)         run_on mac2 "cd ~/cn-project/tls && openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=wrong.test -keyout wrong.key -out wrong.crt 2>/dev/null && sed -i '' -e 's#app.teamX.test.crt#wrong.crt#' -e 's#app.teamX.test.key#wrong.key#' /opt/homebrew/etc/nginx/servers/cn-project.conf && /opt/homebrew/bin/nginx -s reload" ;;
    *) echo "unknown fault. choose: ${faults[*]}"; return 2 ;;
  esac >/dev/null 2>&1
  echo "$f" > "$STATE"
  title "A HIDDEN FAULT HAS BEEN INJECTED"
  echo "  Find it like in the exam:  ${B}scripts/demo.sh F${N}  (or scripts/diagnose.sh)"
  echo "  Wait ~30 s first if you suspect DNS: this Mac may still have a cached answer."
  echo "  When you have a guess:     ${B}scripts/demo.sh answer${N}"
  echo "  To repair everything:      ${B}scripts/demo.sh fix${N}"
}
answer() {
  local f; f="$(cat "$STATE" 2>/dev/null || echo none)"
  echo "The injected fault was: ${B}$f${N}"
  case "$f" in
    dns1-down)          echo "Layer: DNS. Only the primary is down, so the service still works via backup DNS (that's Ext A!)." ;;
    both-dns-down)      echo "Layer: L2 DNS. No phone book → the name can't be resolved → nothing else can even start." ;;
    wrong-record)       echo "Layer: L2 DNS (wrong record). The name resolves, but to Tanmay's Mac, which has no web server → connection refused." ;;
    nginx-down)         echo "Layer: L4 TCP. DNS fine, but nothing listens on port 443 at the front door → refused." ;;
    backend-a-down)     echo "Layer: application. Service still works (B only) - Ext D failover hid it. diagnose shows only one backend in rotation." ;;
    both-backends-down) echo "Layer: L7. DNS, TCP, TLS fine; the front door answers 502 Bad Gateway." ;;
    wrong-cert)         echo "Layer: L5 TLS. Certificate is for wrong.test, not app.teamX.test → verification fails." ;;
  esac
}
fix() {
  title "FIX: putting everything back to normal"
  run_on mac1 "$CN dns start; $CN dns-record $APP_RECORD_IP" 2>&1 | sed 's/^/     /'
  run_on mac2 "$CN dns start; $CN dns-record $APP_RECORD_IP; $CN edge start >/dev/null; rm -f ~/cn-project/tls/wrong.*; $CN edge status" 2>&1 | sed 's/^/     /'
  run_on mac3 "$CN backend start; $CN edge start >/dev/null; $CN edge status" 2>&1 | sed 's/^/     /'
  rm -f "$STATE"
  echo "     (waiting 11 s for nginx to re-check the backends...)"; sleep 11
  wait_normal
  step "Check"; hits 4
  echo "  If this Mac still shows a wrong address, wait 30 s (DNS cache) or run: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
}

case "${1:-}" in
  who) who ;; check) check ;;
  A|a) ext_A ;; B|b) ext_B ;; C|c) ext_C ;; D|d) ext_D ;; E|e) ext_E ;; F|f) ext_F ;;
  break) brk "${2:-}" ;; answer) answer ;; fix) fix ;;
  *) sed -n '2,16p' "$0" ;;
esac
