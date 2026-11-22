#!/bin/bash
# Quick end-to-end check from any CLIENT Mac (DNS -> HTTPS -> load balancing -> caching).
# Usage: scripts/smoke-test.sh [teamX.test]      (for the full layer-by-layer check use scripts/diagnose.sh)
set -euo pipefail
DOMAIN="${1:-teamX.test}"; APP="app.$DOMAIN"
echo "== 1. DNS (system resolver)";  dscacheutil -q host -a name "$APP" | awk '/ip_address/{print "  " $2}' | grep . \
  || { echo "ERROR: cannot resolve $APP - set this Mac's DNS to the team resolvers (sudo scripts/phase2/client-setup.sh)" >&2; exit 1; }
echo "== 2. HTTPS through the edge (certificate must verify, no -k), 6 requests"
for i in 1 2 3 4 5 6; do curl -sS --max-time 8 -D - -o /dev/null "https://$APP/api/status" | awk 'NR==1{printf "  %s %s", $1, $2} tolower($1)=="x-backend:"{printf "  backend=%s", $2} tolower($1)=="x-edge:"{printf "  edge=%s", $2} END{print ""}' | tr -d '\r'; done
echo "== 3. Caching headers + conditional request"
curl -sSI "https://$APP/api/cache" | grep -iE '^HTTP|cache-control|etag' | sed 's/^/  /'
curl -sS -o /dev/null -w '  If-None-Match -> HTTP %{http_code}\n' -H 'If-None-Match: "cn-cache-v1"' "https://$APP/api/cache"
