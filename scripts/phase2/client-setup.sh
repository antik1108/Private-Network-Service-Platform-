#!/bin/bash
# One-time client setup - run ON EACH Mac with sudo (it changes system settings):
#
#   sudo scripts/phase2/client-setup.sh          configure
#   sudo scripts/phase2/client-setup.sh --undo   restore the previous DNS servers
#
# 1. Sets the Wi-Fi DNS servers to  <primary DNS (Mac 1)>  <backup DNS (Mac 2)>
#    (Phase 1 Task B + Phase 2 Extension A: clients list BOTH resolvers).
#    dnsmasq forwards non-project names upstream, so normal Internet still works.
# 2. Removes /etc/resolver/test if it points somewhere else (an old Phase 1
#    leftover that would override the network DNS for *.test).
# 3. Trusts the team CA (tls/teamX-root-ca.crt) in the System keychain so curl
#    and browsers validate https://app.teamX.test without -k (Task E).
# 4. Flushes the macOS DNS cache.
set -euo pipefail
# Works from the repo (scripts/phase2/) or from ~/cn-project/bin/ (copied by deploy.sh).
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/../node.env" ]; then ROOT="$(cd "$HERE/.." && pwd)"; source "$ROOT/team.env"
else ROOT="$(cd "$HERE/../.." && pwd)"; source "$ROOT/team/team.env"; fi
mkdir -p "$ROOT/config"
[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo $0 $*"; exit 1; }
SVC="$(networksetup -listallnetworkservices | grep -m1 -E '^Wi-?Fi$' || echo Wi-Fi)"
SAVE="$ROOT/config/.dns-before-cn-project.txt"

if [ "${1:-}" = "--undo" ]; then
    prev="$(cat "$SAVE" 2>/dev/null || echo Empty)"
    # shellcheck disable=SC2086
    networksetup -setdnsservers "$SVC" $prev
    dscacheutil -flushcache; killall -HUP mDNSResponder
    echo "Restored DNS for $SVC: $(networksetup -getdnsservers "$SVC" | xargs)"; exit 0
fi

cur="$(networksetup -getdnsservers "$SVC")"
if [[ "$cur" == *"any DNS Servers"* ]]; then cur="Empty"; fi
[ -f "$SAVE" ] || { echo "$cur" | xargs > "$SAVE"; echo "Saved previous DNS ($(echo $cur | xargs)) to $SAVE"; }

networksetup -setdnsservers "$SVC" "$DNS1_IP" "$DNS2_IP"
echo "DNS servers for $SVC: $(networksetup -getdnsservers "$SVC" | xargs)"

if [ -f /etc/resolver/test ]; then
    cp /etc/resolver/test "$ROOT/config/.etc-resolver-test.bak"
    rm /etc/resolver/test
    echo "Removed /etc/resolver/test (backup in config/.etc-resolver-test.bak)"
fi

security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ROOT/tls/teamX-root-ca.crt"
echo "Trusted team CA: $(openssl x509 -in "$ROOT/tls/teamX-root-ca.crt" -noout -subject)"

dscacheutil -flushcache; killall -HUP mDNSResponder
echo "DNS cache flushed."
echo
echo "Check:"
echo "  dig app.$TEAM_DOMAIN                      # SERVER: $DNS1_IP"
echo "  curl -sI https://app.$TEAM_DOMAIN/api/status   # no -k, HTTP/2 200"
