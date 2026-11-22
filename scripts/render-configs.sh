#!/bin/bash
# Render every node's configuration from team/team.env into config/rendered/.
#
#   mac1/  primary DNS  : dnsmasq.conf, teamX.hosts
#   mac2/  edge1 + DNS2 : dnsmasq.conf, teamX.hosts, nginx-cn-project.conf
#   mac3/  backends + edge2 : nginx-cn-project.conf, pf-backend-isolation.conf
#
# Usage: scripts/render-configs.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/team/team.env"
OUT="$ROOT/config/rendered"
rm -rf "$OUT"; mkdir -p "$OUT"/mac1 "$OUT"/mac2 "$OUT"/mac3

home_of() { echo "/Users/${1%@*}/cn-project"; }   # user@ip -> /Users/user/cn-project

UPSTREAM_LINES=""
for s in $UPSTREAM_DNS; do UPSTREAM_LINES+="server=$s"$'\n'; done

render() {  # render <template> <out> KEY=VALUE...
    local tpl="$1" out="$2"; shift 2
    local text; text="$(cat "$tpl")"
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        text="${text//@${k}@/$v}"
    done
    if grep -q '@[A-Z_0-9]*@' <<<"$text"; then
        echo "unrendered placeholder in $out:" >&2; grep -o '@[A-Z_0-9]*@' <<<"$text" >&2; exit 1
    fi
    printf '%s\n' "$text" > "$out"
}

hosts_file() {  # the project zone, identical on both resolvers
    cat > "$1" <<EOF
# Project zone for $TEAM_DOMAIN - served by BOTH dnsmasq resolvers.
# Change the IP, then reload: scripts/phase2/cn.sh dns reload  (or cn.sh dns-record <ip>)
$APP_RECORD_IP app.$TEAM_DOMAIN api.$TEAM_DOMAIN
EOF
}

common=(TEAM_DOMAIN="$TEAM_DOMAIN" DNS_TTL="$DNS_TTL" UPSTREAM_SERVER_LINES="${UPSTREAM_LINES%$'\n'}")

# Mac 1 - primary DNS
render "$ROOT/dnsmasq/dnsmasq.conf.template" "$OUT/mac1/dnsmasq.conf" \
    "${common[@]}" DNS_ROLE=primary NODE_IP="$MAC1_IP" CN_HOME="$(home_of "$MAC1_SSH")"
hosts_file "$OUT/mac1/teamX.hosts"

# Mac 2 - backup DNS + primary edge
render "$ROOT/dnsmasq/dnsmasq.conf.template" "$OUT/mac2/dnsmasq.conf" \
    "${common[@]}" DNS_ROLE=backup NODE_IP="$MAC2_IP" CN_HOME="$(home_of "$MAC2_SSH")"
hosts_file "$OUT/mac2/teamX.hosts"
render "$ROOT/nginx/nginx.conf.template" "$OUT/mac2/nginx-cn-project.conf" \
    TEAM_DOMAIN="$TEAM_DOMAIN" EDGE_NAME=edge1-mac2 NODE_IP="$MAC2_IP" \
    BACKEND_A="$BACKEND_A" BACKEND_B="$BACKEND_B" CN_HOME="$(home_of "$MAC2_SSH")"

# Mac 3/4 - standby edge (identical config, different label) + backend firewall
render "$ROOT/nginx/nginx.conf.template" "$OUT/mac3/nginx-cn-project.conf" \
    TEAM_DOMAIN="$TEAM_DOMAIN" EDGE_NAME=edge2-mac3 NODE_IP="$MAC3_IP" \
    BACKEND_A="$BACKEND_A" BACKEND_B="$BACKEND_B" CN_HOME="$(home_of "$MAC3_SSH")"
render "$ROOT/firewall/pf-backend-isolation.conf.template" "$OUT/mac3/pf-backend-isolation.conf" \
    NODE_IP="$MAC3_IP" EDGE1_IP="$EDGE1_IP"

echo "Rendered into $OUT:"
(cd "$OUT" && find . -type f | sort)
