#!/bin/bash
# Extension C - backend service isolation with pf. Run on the BACKEND Mac (Mac 3/4) with sudo.
#
#   sudo scripts/phase2/firewall.sh apply      back up current pf state, load our anchor, enable pf
#   sudo scripts/phase2/firewall.sh status     show our rules + live counters
#   sudo scripts/phase2/firewall.sh rollback   flush our anchor and restore pf to how it was
#
# Rules: config/rendered/mac3/pf-backend-isolation.conf (only the edge may reach 3001/3002).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANCHOR="com.apple/cn-backend-isolation"
RULES="$ROOT/config/rendered/mac3/pf-backend-isolation.conf"
STATE="$ROOT/config/firewall-state"; mkdir -p "$STATE"
[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo $0 $*"; exit 1; }

case "${1:-status}" in
apply)
    # Rollback copy of the ORIGINAL configuration (taken once).
    if [ ! -f "$STATE/pf-before.rules" ]; then
        pfctl -sr 2>/dev/null > "$STATE/pf-before.rules" || true
        pfctl -s info 2>/dev/null | head -1 > "$STATE/pf-before.status" || true
        cp /etc/pf.conf "$STATE/etc-pf.conf.bak"
        echo "Saved rollback copy in $STATE/"
    fi
    pfctl -nf "$RULES" -a "$ANCHOR"                       # syntax check first
    pfctl -a "$ANCHOR" -f "$RULES" 2>/dev/null
    # -E takes a reference on pf; keep the token so rollback only releases ours.
    pfctl -E 2>&1 | awk '/Token/{print $NF}' > "$STATE/pf-token"
    echo "Applied. Anchor $ANCHOR now contains:"; pfctl -a "$ANCHOR" -sr ;;
status)
    pfctl -s info 2>/dev/null | head -1
    echo "--- anchor $ANCHOR (with counters):"; pfctl -a "$ANCHOR" -vsr 2>/dev/null ;;
rollback)
    pfctl -a "$ANCHOR" -F all 2>/dev/null || true
    if [ -s "$STATE/pf-token" ]; then pfctl -X "$(cat "$STATE/pf-token")" 2>/dev/null || true; rm -f "$STATE/pf-token"; fi
    cmp -s /etc/pf.conf "$STATE/etc-pf.conf.bak" 2>/dev/null || echo "WARNING: /etc/pf.conf differs from backup"
    echo "Rolled back. Anchor now: $(pfctl -a "$ANCHOR" -sr 2>/dev/null | wc -l | xargs) rules"
    pfctl -s info 2>/dev/null | head -1
    echo "Original state was: $(cat "$STATE/pf-before.status" 2>/dev/null)" ;;
*) echo "usage: sudo $0 apply|status|rollback"; exit 2 ;;
esac
