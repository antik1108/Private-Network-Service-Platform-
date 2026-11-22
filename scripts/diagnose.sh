#!/bin/bash
# diagnose.sh - Extension F: systematic, layer-by-layer fault isolation.
# Run on ANY client Mac. No sudo, no SSH needed (optional deep checks use SSH).
#
#   scripts/diagnose.sh                 diagnose https://app.teamX.test/api/status
#   scripts/diagnose.sh api.teamX.test  another name
#   DEEP=1 scripts/diagnose.sh          also check the edge->backend hop over SSH
#
# Order (bottom-up, stop at the first broken layer):
#   L1 client network  ->  L2 DNS  ->  L3 IP reachability  ->  L4 TCP port
#   ->  L5 TLS  ->  L6 HTTP via edge  ->  L7 edge -> backend
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="$ROOT/team/team.env"; [ -f "$ENV" ] || ENV="$HOME/cn-project/team.env"
source "$ENV"
HOST="${1:-app.$TEAM_DOMAIN}"; PORT="${PORT:-443}"; PATH_="/api/status"
CA="$ROOT/tls/teamX-root-ca.crt"; [ -f "$CA" ] || CA="$HOME/cn-project/tls/teamX-root-ca.crt"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
ok()   { echo "  ${G}OK${N}    $*"; }
bad()  { echo "  ${R}FAIL${N}  $*"; }
warn() { echo "  ${Y}WARN${N}  $*"; }
verdict() { echo; echo "${R}>>> FIRST FAILING LAYER: $1${N}"; echo "    likely cause: $2"; echo "    next step:    $3"; exit 1; }
hdr()  { echo; echo "[$1] $2"; }

echo "Diagnosing https://$HOST:$PORT$PATH_   ($(date '+%F %T') from $(hostname -s))"

hdr L1 "Client network (interface, IP, gateway)"
IP="$(ipconfig getifaddr en0 || true)"; GW="$(ipconfig getoption en0 router 2>/dev/null || true)"
[ -n "$IP" ] && ok "en0 has $IP, gateway $GW" || verdict "L1 client network" "Wi-Fi down / no DHCP lease" "reconnect Wi-Fi, check 'ipconfig getifaddr en0'"
SUBNET_OK=1
for v in DNS1_IP DNS2_IP EDGE1_IP; do [[ "${!v%.*.*}" == "${IP%.*.*}" ]] || SUBNET_OK=0; done
[ $SUBNET_OK = 1 ] || warn "team.env IPs are not in this Mac's network ($IP) - did DHCP change addresses?"

hdr L2 "DNS - which servers does this client use, and do they answer?"
# Network > DNS servers (scutil also sees them when Tailscale/VPN owns /etc/resolv.conf)
SERVERS="$( { networksetup -getdnsservers Wi-Fi 2>/dev/null; scutil --dns | awk '/nameserver\[/{print $3}'; } | grep -E '^[0-9a-f.:]+$' | awk '!s[$0]++' | xargs)"
echo "  system resolvers: ${SERVERS:-none}"
[[ " $SERVERS " == *" $DNS1_IP "* ]] || warn "primary team DNS $DNS1_IP is not configured on this client"
[[ " $SERVERS " == *" $DNS2_IP "* ]] || warn "backup team DNS $DNS2_IP is not configured on this client"
A1="$(dig @"$DNS1_IP" "$HOST" +short +time=2 +tries=1 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)"
A2="$(dig @"$DNS2_IP" "$HOST" +short +time=2 +tries=1 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)"
[ -n "$A1" ] && ok "primary $DNS1_IP: $HOST -> $A1" || bad "primary $DNS1_IP gives no answer"
[ -n "$A2" ] && ok "backup  $DNS2_IP: $HOST -> $A2" || bad "backup  $DNS2_IP gives no answer"
SYS="$(dscacheutil -q host -a name "$HOST" | awk '/ip_address/{print $2}' | head -1)"
[ -n "$SYS" ] && ok "system resolver (what curl/browser use): $HOST -> $SYS" || bad "system resolver cannot resolve $HOST"
[ -n "$A1$A2" ] && [ -n "$A1" ] && [ -n "$A2" ] && [ "$A1" != "$A2" ] && warn "primary and backup DISAGREE ($A1 vs $A2) - zone out of sync"
[ -z "$SYS" ] && [ -z "$A1$A2" ] && verdict "L2 DNS (servers)" "dnsmasq stopped on both resolvers, or wrong record name" "on Mac 1/2: ~/cn-project/bin/cn.sh dns status; check teamX.hosts"
[ -z "$SYS" ] && verdict "L2 DNS (client config)" "this client is not using the team DNS servers" "sudo scripts/phase2/client-setup.sh (or System Settings > Network > DNS)"
TARGET="$SYS"
EDGES=" $EDGE1_IP $EDGE2_IP "; NOT_EDGE=0
[[ "$EDGES" == *" $TARGET "* ]] || NOT_EDGE=1
[ $NOT_EDGE = 0 ] || warn "$HOST resolves to $TARGET, which is NOT one of the edges ($EDGE1_IP/$EDGE2_IP) - wrong record?"
CACHED_TTL="$(dig @"$DNS1_IP" "$HOST" +noall +answer 2>/dev/null | awk '{print $2}' | head -1)"
[ -n "$CACHED_TTL" ] && echo "  record TTL: ${CACHED_TTL}s (a stale client cache lasts at most this long)"

hdr L3 "IP reachability to $TARGET"
if nc -z -G 3 "$TARGET" 22 2>/dev/null || nc -z -G 3 "$TARGET" "$PORT" 2>/dev/null || ping -c 1 -t 2 "$TARGET" >/dev/null 2>&1; then
    ok "$TARGET is reachable"
else
    verdict "L3 IP / network" "$TARGET is not reachable (host off, wrong IP in DNS, different Wi-Fi)" "ping $TARGET; check the record with dig; check team.env IPs"
fi

hdr L4 "TCP connect to $TARGET:$PORT"
T0=$(date +%s)
if nc -z -G 4 "$TARGET" "$PORT" 2>/dev/null; then ok "TCP $PORT open (3-way handshake completed)"
else
    DT=$(( $(date +%s) - T0 ))
    if [ $DT -ge 3 ]; then verdict "L4 TCP (filtered)" "SYN got no answer - a firewall is dropping packets to :$PORT" "check pf on the edge (sudo pfctl -sr), wrong port?"
    elif [ $NOT_EDGE = 1 ]; then verdict "L2 DNS (wrong record) -> seen at L4" "$HOST resolves to $TARGET, which is not an edge, and nothing listens on :$PORT there" "fix the record on BOTH resolvers: cn.sh dns-record $EDGE1_IP (then wait TTL or flush client cache)"
    else verdict "L4 TCP (refused)" "host is up but nothing listens on :$PORT - nginx stopped or listening on another port" "on the edge: ~/cn-project/bin/cn.sh edge status; nginx -t; lsof -iTCP -sTCP:LISTEN"; fi
fi

hdr L5 "TLS handshake + certificate validation"
TLS="$(echo | openssl s_client -connect "$TARGET:$PORT" -servername "$HOST" -CAfile "$CA" -verify_return_error 2>&1)"
PROTO="$(grep -m1 -E '^ *Protocol *:|New, TLS' <<<"$TLS" | xargs)"
if grep -q 'Verify return code: 0' <<<"$TLS"; then
    ok "handshake OK ($PROTO), certificate chain verifies against the team CA"
    echo | openssl s_client -connect "$TARGET:$PORT" -servername "$HOST" 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName -enddate 2>/dev/null | sed 's/^/        /'
else
    REASON="$(grep -m1 -E 'verify error|Verify return code|alert|errno|unable' <<<"$TLS")"
    verdict "L5 TLS" "${REASON:-handshake failed} (wrong/expired cert, name not in SAN, untrusted CA, or plain HTTP on 443)" "openssl s_client -connect $TARGET:$PORT -servername $HOST; check ssl_certificate paths in nginx config"
fi
if ! curl -s -o /dev/null --max-time 5 "https://$HOST:$PORT/edge-health"; then
    warn "system trust store does not accept the cert (curl without --cacert failed) - run client-setup.sh to trust the team CA"
fi

hdr L6 "HTTP through the edge"
OUT="$(curl -s --cacert "$CA" --max-time 8 -D - -o /tmp/.cn-diag-body "https://$HOST:$PORT$PATH_" 2>&1)"; RC=$?
CODE="$(awk 'NR==1{print $2}' <<<"$OUT")"
EDGE="$(awk 'tolower($1)=="x-edge:"{print $2}' <<<"$OUT" | tr -d '\r')"
BACK="$(awk 'tolower($1)=="x-backend:"{print $2}' <<<"$OUT" | tr -d '\r')"
case "$CODE" in
    200) ok "HTTP 200 from edge=$EDGE backend=$BACK" ;;
    502|504) bad "HTTP $CODE from edge=$EDGE: the edge is fine, the BACKENDS are not answering"
             verdict "L7 edge -> backend" "both backends down, wrong upstream IP/port in nginx, or backend firewall blocking the edge" "on Mac 3: cn.sh backend status; on Mac 2: curl http://$BACKEND_A/api/status; check nginx-error.log" ;;
    404) verdict "L6 HTTP (routing)" "nginx answered 404: server_name / location mismatch (Host header not app.$TEAM_DOMAIN?)" "check server_name in cn-project.conf" ;;
    "") verdict "L6 HTTP" "no HTTP response (curl exit $RC)" "curl -v https://$HOST$PATH_" ;;
    *) bad "HTTP $CODE"; verdict "L6 HTTP" "unexpected status $CODE" "curl -v https://$HOST$PATH_; check nginx and backend logs" ;;
esac

hdr L7 "Load balancing / backend health (6 requests)"
SEEN=""
for i in 1 2 3 4 5 6; do
    b="$(curl -s --cacert "$CA" --max-time 5 -D - -o /dev/null "https://$HOST:$PORT$PATH_" | awk 'tolower($1)=="x-backend:"{print $2}' | tr -d '\r')"
    SEEN+="${b:-?} "
done
echo "  backends seen: $SEEN"
[[ "$SEEN" == *A* && "$SEEN" == *B* ]] && ok "both backends in rotation" || warn "only one backend answering - the other is down or marked failed (service still up)"

if [ "${DEEP:-0}" = 1 ]; then
    hdr DEEP "Edge -> backend hop (over SSH to Mac 2)"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$MAC2_SSH" "for b in $BACKEND_A $BACKEND_B; do curl -s -m 3 -o /dev/null -w \"  \$b -> %{http_code}\n\" http://\$b/api/status || echo \"  \$b -> unreachable\"; done; tail -3 ~/cn-project/logs/nginx-error.log"
fi
echo; echo "${G}>>> All layers healthy.${N}"
