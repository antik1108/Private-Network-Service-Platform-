#!/bin/bash
# Phase 1 regression + Phase 2 extension tests. Run from the operator Mac
# (Mac 3/4, Antik) - it drives the other Macs over SSH. Every run is logged
# to evidence/phase2/logs/<test>.log so the output itself is the evidence.
#
#   scripts/phase2/run-tests.sh p1          Phase 1 regression (Tasks A-F)
#   scripts/phase2/run-tests.sh p1fail      Phase 1 failure demonstrations (section 6.3)
#   scripts/phase2/run-tests.sh extA        backup DNS failover
#   scripts/phase2/run-tests.sh extB        TTL + controlled record change
#   scripts/phase2/run-tests.sh extC        service isolation (needs: sudo firewall.sh apply)
#   scripts/phase2/run-tests.sh extD        HA failover of Backend A
#   scripts/phase2/run-tests.sh extE        DNS-based edge cutover
#   scripts/phase2/run-tests.sh all
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/team/team.env"
source "$ROOT/scripts/lib/remote.sh"
LOGDIR="$ROOT/evidence/phase2/logs"; mkdir -p "$LOGDIR"
D="$TEAM_DOMAIN"; APP="app.$D"
CA="$ROOT/tls/teamX-root-ca.crt"
CN='~/cn-project/bin/cn.sh'

hr()   { printf '\n==== %s ====\n' "$*"; }
step() { printf '\n--- [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
show() { printf '$ %s\n' "$*"; eval "$*" 2>&1; }                          # run locally, echo the command
on()   { local n="$1"; shift; printf '%s$ %s\n' "$n" "$*"; run_on "$n" "$*" 2>&1; }   # run on a node
# Client mode: normally curl uses the system resolver (team DNS configured on this Mac).
# If this Mac's DNS is not set up yet, ask the team DNS explicitly and pin curl to that
# answer (still name-based, still certificate-verified), and say so in the log.
SYSOK=1; dscacheutil -q host -a name "$APP" | grep -q ip_address || SYSOK=0
curlx() {
    if [ $SYSOK = 1 ]; then curl "$@"; return; fi
    local ip; ip="$(dig @"$DNS1_IP" "$APP" +short +time=2 +tries=1 | tail -1)"
    [ -n "$ip" ] || ip="$(dig @"$DNS2_IP" "$APP" +short +time=2 +tries=1 | tail -1)"
    curl --cacert "$CA" --resolve "$APP:443:$ip" --resolve "$APP:80:$ip" --resolve "$APP:8443:$ip" "$@"
}
# One HTTPS request; prints status, backend, edge.
hit()  { curlx -s -o /dev/null --max-time 6 -D - "https://$APP/api/status" 2>&1 \
           | awk '{l=tolower($0)} NR==1{c=$2} l~/^x-backend/{b=$2} l~/^x-edge/{e=$2} END{printf "%s backend=%s edge=%s", (c?c:"000"), b, e}' | tr -d '\r'
         echo; }
sysresolve() { dscacheutil -q host -a name "$1" | awk '/ip_address/{print $2}' | xargs; }
PASS=0; FAIL=0
check() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# --------------------------------------------------------------- Phase 1
t_p1() {
    hr "PHASE 1 REGRESSION  $(date)"
    step "Task A - inventory of each Mac (IPv4, prefix, gateway, interface, MAC)"
    for n in mac1 mac2 mac3; do
        on "$n" 'echo "host=$(hostname -s) if=en0 ip=$(ipconfig getifaddr en0) mask=$(ipconfig getoption en0 subnet_mask) gw=$(ipconfig getoption en0 router) mac=$(ifconfig en0 | awk "/ether/{print \$2}")"'
    done
    step "Task A - ping matrix (every pair)"
    on mac1 "ping -c 2 -q $MAC2_IP | tail -2; ping -c 2 -q $MAC3_IP | tail -2"
    on mac2 "ping -c 2 -q $MAC1_IP | tail -2; ping -c 2 -q $MAC3_IP | tail -2"
    step "Task B - both resolvers answer the project names"
    for s in "$DNS1_IP" "$DNS2_IP"; do show "dig @$s $APP +noall +answer +stats | grep -E 'IN\s+A|SERVER'"; show "dig @$s api.$D +short"; done
    check "primary DNS answers $APP" "[ \"\$(dig @$DNS1_IP $APP +short)\" = $APP_RECORD_IP ]"
    check "backup DNS answers $APP"  "[ \"\$(dig @$DNS2_IP $APP +short)\" = $APP_RECORD_IP ]"
    step "Task B - client system resolver (no @server): uses the team DNS"
    show "grep nameserver /etc/resolv.conf"
    show "dig $APP +noall +answer +stats | grep -E 'IN\s+A|SERVER'"
    show "dig @8.8.8.8 $APP +noall +comments | grep status   # public DNS has never heard of it"
    step "Task C - backends from the edge (Mac 2) - LAN reachable, X-Backend header"
    on mac2 "curl -s -i http://$BACKEND_A/api/status | grep -iE '^HTTP|^X-Backend|backend'"
    on mac2 "curl -s -i http://$BACKEND_B/api/status | grep -iE '^HTTP|^X-Backend|backend'"
    on mac3 "lsof -nP -iTCP:3001 -iTCP:3002 -sTCP:LISTEN | awk 'NR>1{print \$1, \$9}'"
    step "Task D+E - HTTPS by name, certificate verified (no -k), HTTP/2 + HTTP/1.1"
    show "curlx -sv https://$APP/api/status -o /dev/null 2>&1 | grep -E 'Connected to|SSL connection|ALPN|subject:|issuer:|SSL certificate verify|^< HTTP|^< x-'"
    show "curlx -s --http1.1 -I https://$APP/api/status | head -1"
    check "TLS verifies (system trust store, or team CA when pinned)" "curlx -s -o /dev/null https://$APP/api/status"
    step "Task D - round robin (8 requests)"
    for i in 1 2 3 4 5 6 7 8; do printf '  #%s ' "$i"; hit; done
    step "Task F - caching: Cache-Control/ETag, then conditional request -> 304"
    show "curlx -sI https://$APP/api/cache | grep -iE '^HTTP|cache-control|etag|x-backend'"
    show "curlx -si -H 'If-None-Match: \"cn-cache-v1\"' https://$APP/api/cache | grep -iE '^HTTP|etag|content-length'"
    check "conditional GET returns 304" "[ \"\$(curlx -s -o /dev/null -w '%{http_code}' -H 'If-None-Match: \"cn-cache-v1\"' https://$APP/api/cache)\" = 304 ]"
    show "curlx -sI https://$APP/api/status | grep -i cache-control   # dynamic endpoint is never cached"
    step "Port 80 redirects to HTTPS"
    show "curlx -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://$APP/api/status"
}

# --------------------------------------------------------------- Phase 1 failures (6.3)
t_p1fail() {
    hr "PHASE 1 FAILURE DEMONSTRATIONS  $(date)"
    step "F1 Wrong DNS server: ask a resolver that does not know our zone"
    show "dig @8.8.8.8 $APP +noall +comments | grep status"
    show "dig @$MAC3_IP $APP +time=2 +tries=1 | grep -E 'status|timed out|refused'   # no DNS server on Mac 3"
    show "nc -z -G 3 $EDGE1_IP 443 && echo 'but TCP to the edge IP still works -> DNS and IP are independent layers'"
    step "F2 Record points to a wrong IP (resolve OK, connect to wrong place)"
    show "curlx -s --max-time 4 --resolve $APP:443:$DNS1_IP https://$APP/api/status; echo \"exit=\$? (Mac 1 has no web server: TCP refused)\""
    step "F3 One backend stopped -> service continues"
    on mac3 "$CN backend stop A"
    for i in 1 2 3 4; do printf '  #%s ' "$i"; hit; done
    on mac3 "$CN backend start A"
    step "F4 Both backends stopped -> DNS + TLS fine, 502 from the edge"
    on mac3 "$CN backend stop A; $CN backend stop B"
    show "dig $APP +short"
    show "curlx -sv https://$APP/api/status 2>&1 | grep -E 'SSL certificate verify|^< HTTP|^< x-edge'"
    check "both down -> 502" "[ \"\$(curlx -s -o /dev/null -w '%{http_code}' https://$APP/api/status)\" = 502 ]"
    on mac2 "tail -3 ~/cn-project/logs/nginx-error.log | cut -c1-220"
    on mac3 "$CN backend start A; $CN backend start B"
    step "F5 Wrong destination port: host reachable, port closed"
    show "curlx -s --max-time 4 https://$APP:8443/api/status; echo \"exit=\$? (7 = connection refused on :8443)\""
    show "nc -z -G 3 $EDGE1_IP 443 && echo ':443 open'"
}

# --------------------------------------------------------------- Ext A
t_extA() {
    hr "EXTENSION A - BACKUP DNS RESOLVER  $(date)"
    step "Client resolver list (both servers)"
    show "grep nameserver /etc/resolv.conf"
    on mac1 "$CN dns status"; on mac2 "$CN dns status"
    show "dig $APP +noall +answer +stats | grep -E 'IN\s+A|SERVER'"
    step "Stop the PRIMARY (dnsmasq on Mac 1)"
    on mac1 "$CN dns stop"
    show "dig @$DNS1_IP $APP +time=2 +tries=1 | grep -E 'refused|timed out|status'"
    step "The backup resolver has the same records"
    show "dig @$DNS2_IP $APP +noall +answer +stats | grep -E 'IN\s+A|SERVER'"
    step "System resolver (what browsers/curl use): wait for cached entry to expire, then resolve again"
    sleep $((DNS_TTL + 2))
    show "dscacheutil -q host -a name $APP | grep ip_address"
    printf '  HTTPS via backup DNS: '; hit
    check "client resolves with primary down" "[ -n \"\$(sysresolve $APP)\" ]"
    on mac2 "grep -iE 'query\[A\] $APP' ~/cn-project/logs/dnsmasq.log | tail -3   # backup served the client"
    step "DNS failure vs application failure"
    show "dig @$DNS2_IP $APP +short   # name resolution works ..."
    on mac3 "$CN backend stop A; $CN backend stop B"
    show "curlx -s -o /dev/null -w 'HTTP %{http_code}\n' https://$APP/api/status   # ... but the service is down (502)"
    on mac3 "$CN backend start A; $CN backend start B"
    step "Restore the primary"
    on mac1 "$CN dns start"
    show "dig $APP +noall +answer +stats | grep -E 'IN\s+A|SERVER'"
}

# --------------------------------------------------------------- Ext B
t_extB() {
    hr "EXTENSION B - TTL AND CONTROLLED RECORD CHANGE  $(date)"
    local OLD="$APP_RECORD_IP" NEW="$EDGE2_IP"
    step "Record TTL is $DNS_TTL s (answer section 2nd column)"
    show "dig @$DNS1_IP $APP +noall +answer"
    step "Client resolves -> answer is now cached by the client (mDNSResponder)"
    show "dscacheutil -q host -a name $APP | grep ip_address"
    local t0; t0=$(date +%s)
    step "Change the record to $NEW on BOTH resolvers"
    on mac1 "$CN dns-record $NEW"; on mac2 "$CN dns-record $NEW"
    show "dig @$DNS1_IP $APP +noall +answer   # authoritative answer changes immediately"
    step "Poll the client every 5 s: cached (old) answer until the TTL expires"
    local i=0 ans flipped=0
    while [ $i -lt 9 ]; do
        ans="$(sysresolve $APP)"; printf '  t=+%02ds client=%-14s server=%s\n' $(( $(date +%s) - t0 )) "$ans" "$(dig @$DNS1_IP $APP +short)"
        [ "$ans" = "$NEW" ] && flipped=1 && break
        sleep 5; i=$((i+1))
    done
    check "client switched to the new IP within TTL+slack" "[ $flipped = 1 ]"
    step "Change it back, then flush the client cache manually (needs sudo) -> immediate change"
    show "dscacheutil -q host -a name $APP | grep ip_address   # re-cache NEW"
    on mac1 "$CN dns-record $OLD"; on mac2 "$CN dns-record $OLD"
    show "dscacheutil -q host -a name $APP | grep ip_address   # still NEW (cached)"
    if sudo -n true 2>/dev/null; then
        show "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
        show "dscacheutil -q host -a name $APP | grep ip_address   # OLD immediately after flush"
    else
        echo "  (no passwordless sudo: run 'sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder' yourself;"
        echo "   waiting out the TTL instead)"
        local k=0; while [ $k -lt 12 ]; do a="$(sysresolve $APP)"; printf '  +%02ds client=%s\n' $((k*5)) "$a"; [ "$a" = "$OLD" ] && break; sleep 5; k=$((k+1)); done
    fi
}

# --------------------------------------------------------------- Ext C
t_extC() {
    hr "EXTENSION C - SERVICE ISOLATION  $(date)"
    step "Firewall rules active on the backend Mac (anchor com.apple/cn-backend-isolation)"
    cat "$ROOT/config/rendered/mac3/pf-backend-isolation.conf" | grep -vE '^\s*(#|$)'
    step "Edge (Mac 2) -> backends: allowed"
    on mac2 "curl -s -m 4 -o /dev/null -w 'A: %{http_code}\n' http://$BACKEND_A/api/status; curl -s -m 4 -o /dev/null -w 'B: %{http_code}\n' http://$BACKEND_B/api/status"
    step "Client (Mac 1) -> backends directly: blocked (SYN dropped -> timeout)"
    on mac1 "curl -s -m 4 -o /dev/null -w 'A: %{http_code}\n' http://$BACKEND_A/api/status; echo exit=\$?; nc -z -G 3 ${BACKEND_B%:*} ${BACKEND_B#*:}; echo nc_exit=\$?"
    check "edge reaches backend A" "[ \"\$(run_on mac2 \"curl -s -m 4 -o /dev/null -w '%{http_code}' http://$BACKEND_A/api/status\")\" = 200 ]"
    check "client blocked from backend A" "! run_on mac1 \"curl -s -m 4 -o /dev/null http://$BACKEND_A/api/status\""
    step "Client through the edge: still works"
    on mac1 "curl -s --cacert ~/cn-project/tls/teamX-root-ca.crt --resolve $APP:443:$EDGE1_IP -o /dev/null -w 'via edge: %{http_code}\n' https://$APP/api/status"
}

# --------------------------------------------------------------- Ext D
t_extD() {
    hr "EXTENSION D - HIGH-AVAILABILITY FAILOVER  $(date)"
    step "Both healthy: round robin"
    for i in 1 2 3 4; do printf '  #%s ' "$i"; hit; done
    step "Stop Backend A"
    on mac3 "$CN backend stop A"
    local codes=""
    for i in 1 2 3 4 5 6 7 8; do r="$(hit)"; printf '  #%s %s\n' "$i" "$r"; codes+="${r%% *} "; done
    check "all 8 requests succeeded via B" "[ \"\$(echo $codes | tr ' ' '\n' | sort -u | xargs)\" = 200 ]"
    on mac2 "grep -E 'upstream_status=502|upstream_status=50[0-9], ' ~/cn-project/logs/nginx-access.log | tail -2; grep -E 'refused|temporarily disabled' ~/cn-project/logs/nginx-error.log | tail -2 | cut -c1-200"
    step "Restart Backend A - after fail_timeout (10 s) nginx retries it and it rejoins"
    on mac3 "$CN backend start A"
    sleep 11
    for i in 1 2 3 4 5 6; do printf '  #%s ' "$i"; hit; done
    on mac2 "tail -6 ~/cn-project/logs/nginx-access.log | awk '{print \$NF, \$(NF-1), \$(NF-2)}'"
}

# --------------------------------------------------------------- Ext E
t_extE() {
    hr "EXTENSION E - DNS-BASED EDGE CUTOVER  $(date)"
    step "Standby edge (Mac 3) runs the same config; prove it serves before cutover"
    show "curlx -s --resolve $APP:443:$EDGE2_IP -o /dev/null -w 'standby: %{http_code}\n' -D - https://$APP/edge-health | grep -iE 'x-edge|standby'"
    step "Client A (this Mac) primes its cache: must be on edge1 before we start"
    local w=0 r0
    while :; do r0="$(hit)"; [[ "$r0" == *edge1* ]] && break; w=$((w+1)); [ $w -gt 20 ] && { echo "  client never reached edge1 - aborting"; return 1; }; sleep 4; done
    printf '  %s\n' "$r0"
    local t0; t0=$(date +%s)
    step "CUTOVER: app.$D -> $EDGE2_IP on both resolvers"
    on mac1 "$CN dns-record $EDGE2_IP"; on mac2 "$CN dns-record $EDGE2_IP"
    step "Client B (Mac 1) - a NEW lookup - goes to the standby immediately"
    on mac1 "curl -s --cacert ~/cn-project/tls/teamX-root-ca.crt -D - -o /dev/null https://$APP/api/status | grep -iE 'x-edge|x-backend'; dscacheutil -q host -a name $APP | grep ip_address"
    step "Client A keeps hitting the OLD edge until its cached answer expires"
    local i=0 r moved=0
    while [ $i -lt 25 ]; do
        r="$(hit)"; printf '  t=+%02ds %s\n' $(( $(date +%s) - t0 )) "$r"
        [[ "$r" == *edge2* ]] && moved=1 && break
        sleep 4; i=$((i+1))
    done
    check "client A moved to edge2 after TTL" "[ $moved = 1 ]"
    step "Old edge can now be stopped for maintenance - nobody notices"
    on mac2 "$CN edge stop"
    printf '  '; hit
    step "Roll back: edge1 up, record back to $EDGE1_IP"
    on mac2 "$CN edge start >/dev/null; $CN edge status"
    on mac1 "$CN dns-record $EDGE1_IP"; on mac2 "$CN dns-record $EDGE1_IP"
}

run() { local t="$1" log="$LOGDIR/$1.log"; { [ $SYSOK = 1 ] || echo "NOTE: this client's DNS is not set to the team resolvers yet - curl is pinned to the team DNS answer."; "t_$t"; } > >(tee "$log") 2>&1; sleep 0.5; echo "log: ${log#$ROOT/}"; }
case "${1:-}" in
    p1|p1fail|extA|extB|extC|extD|extE) run "$1" ;;
    all) for t in p1 p1fail extA extB extD extE; do run "$t"; done ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
esac
echo "RESULT: $PASS passed, $FAIL failed"
