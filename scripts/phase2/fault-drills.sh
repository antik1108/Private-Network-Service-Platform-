#!/bin/bash
# Extension F practice: inject a realistic fault, run diagnose.sh, revert.
# Run from the operator Mac (Antik). Output -> evidence/phase2/logs/extF-drills.log
#
#   scripts/phase2/fault-drills.sh            all drills
#   scripts/phase2/fault-drills.sh 3          only drill 3
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/team/team.env"; source "$ROOT/scripts/lib/remote.sh"
CN='~/cn-project/bin/cn.sh'
LOG="$ROOT/evidence/phase2/logs/extF-drills.log"
SITE=/opt/homebrew/etc/nginx/servers/cn-project.conf
NGX=/opt/homebrew/bin/nginx

diag() { "$ROOT/scripts/diagnose.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^\[|OK|FAIL|WARN|>>>|likely|next step' ; }
wait_ttl() { echo "  (waiting ${DNS_TTL}s + 20s slack so this client's cached DNS answer expires)"; sleep $((DNS_TTL + 20)); }
drill() { printf '\n######## DRILL %s: %s  (%s)\n' "$1" "$2" "$(date +%T)"; echo "FAULT INJECTED: $3"; }

d1() { drill 1 "DNS record points to the wrong IP" "app.teamX.test -> $MAC1_IP (a Mac with no web server)"
       run_on mac1 "$CN dns-record $MAC1_IP" >/dev/null; run_on mac2 "$CN dns-record $MAC1_IP" >/dev/null; wait_ttl
       diag
       run_on mac1 "$CN dns-record $APP_RECORD_IP" >/dev/null; run_on mac2 "$CN dns-record $APP_RECORD_IP" >/dev/null; echo "REVERTED"; wait_ttl; }
d2() { drill 2 "Both DNS resolvers down" "dnsmasq stopped on Mac 1 and Mac 2"
       run_on mac1 "$CN dns stop" >/dev/null; run_on mac2 "$CN dns stop" >/dev/null; wait_ttl
       diag
       run_on mac1 "$CN dns start" >/dev/null; run_on mac2 "$CN dns start" >/dev/null; echo "REVERTED"; }
d3() { drill 3 "Edge web server stopped" "nginx stopped on Mac 2"
       run_on mac2 "$CN edge stop" >/dev/null
       diag
       run_on mac2 "$CN edge start" >/dev/null; echo "REVERTED"; }
d4() { drill 4 "Wrong upstream ports in the edge config" "nginx upstreams changed to :3011/:3012"
       run_on mac2 "sed -i '' -e 's/:3001 /:3011 /' -e 's/:3002 /:3012 /' $SITE && $NGX -s reload"; sleep 1
       DEEP=1 "$ROOT/scripts/diagnose.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^\[|OK|FAIL|WARN|>>>|likely|next step|->'
       run_on mac2 "$CN edge start" >/dev/null; echo "REVERTED (config re-installed from ~/cn-project/nginx/cn-project.conf)"; }
d5() { drill 5 "Edge serves the wrong certificate" "nginx given a self-signed cert for wrong.test"
       run_on mac2 "cd ~/cn-project/tls && openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=wrong.test -keyout wrong.key -out wrong.crt 2>/dev/null && sed -i '' -e 's#app.teamX.test.crt#wrong.crt#' -e 's#app.teamX.test.key#wrong.key#' $SITE && $NGX -s reload"; sleep 1
       diag
       run_on mac2 "$CN edge start >/dev/null; rm -f ~/cn-project/tls/wrong.*"; echo "REVERTED"; }
d6() { drill 6 "Both backends down" "Flask backends A and B stopped on Mac 3/4"
       run_on mac3 "$CN backend stop" >/dev/null
       diag
       run_on mac3 "$CN backend start" >/dev/null; echo "REVERTED"; }

{
  echo "Extension F practice drills - $(date) - client $(hostname -s)"
  echo "Method: diagnose.sh checks L1 network -> L2 DNS -> L3 IP -> L4 TCP -> L5 TLS -> L6 HTTP -> L7 edge->backend and stops at the first failure."
  if [ -n "${1:-}" ]; then "d$1"; else for i in 1 2 3 4 5 6; do "d$i"; done; fi
  printf '\n######## FINAL HEALTH CHECK (after nginx fail_timeout)\n'; sleep 11; diag
} 2>&1 | tee "$LOG"
