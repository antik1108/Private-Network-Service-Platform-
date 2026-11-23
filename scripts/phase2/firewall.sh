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
    [ -f "$RULES" ] || { echo "ERROR: $RULES missing - run scripts/render-configs.sh"; exit 1; }
    pfctl -nf "$RULES" -a "$ANCHOR" 2>&1 | grep -v -E 'ALTQ|^$' || true   # syntax check (prints errors only)
    pfctl -a "$ANCHOR" -f "$RULES" 2>&1 | grep -v -E 'ALTQ|flushing of rules|^$' || true
    # -E takes a reference on pf; keep the token so rollback only releases ours.
    { pfctl -E 2>&1 || true; } | awk '/Token/{print $NF}' > "$STATE/pf-token"
    n="$(pfctl -a "$ANCHOR" -sr 2>/dev/null | grep -c . || true)"
    if [ "${n:-0}" -ge 3 ]; then
        echo "APPLIED: $n rules loaded in anchor $ANCHOR (pf $(pfctl -s info 2>/dev/null | head -1 | awk '{print $2}'))"
        pfctl -a "$ANCHOR" -sr
        pfctl -sr 2>/dev/null | grep -q 'anchor "com.apple/\*"' || echo "WARNING: main ruleset does not reference com.apple/* - rules may not be evaluated"
    else
        echo "ERROR: rules did NOT load (anchor has ${n:-0} rules). Rules file: $RULES"; exit 1
    fi ;;
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
