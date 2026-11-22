#!/bin/bash
# Push the rendered configuration bundle to every Mac and (re)start services.
# Run from the operator Mac (any team Mac with SSH access to the others).
#
#   scripts/deploy.sh            render + copy configs + restart services
#   scripts/deploy.sh --tls      also (re)issue the edge certificate on Mac 2
#   scripts/deploy.sh --no-start only copy files
#
# Each node gets ~/cn-project/ :
#   bin/cn.sh  node.env  dnsmasq/  nginx/  tls/  logs/  run/  backup/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/team/team.env"
source "$ROOT/scripts/lib/remote.sh"
DO_TLS=0; DO_START=1
for a in "$@"; do case "$a" in --tls) DO_TLS=1 ;; --no-start) DO_START=0 ;; esac; done

"$ROOT/scripts/render-configs.sh" >/dev/null
R="$ROOT/config/rendered"

prep() {  # prep <node> <roles>
    local n="$1" roles="$2" ssh repo
    ssh="$(node_ssh "$n")"; repo="$(node_dir "$n")"
    run_on "$n" "mkdir -p ~/cn-project/{bin,dnsmasq,nginx,tls,logs,run,backup}"
    put "$n" "$ROOT/scripts/phase2/cn.sh" "cn-project/bin/cn.sh"
    put "$n" "$ROOT/scripts/phase2/client-setup.sh" "cn-project/bin/client-setup.sh"
    put "$n" "$ROOT/team/team.env" "cn-project/team.env"
    printf 'NODE=%s\nROLES="%s"\nCN_REPO=%s\nTEAM_DOMAIN=%s\n' "$n" "$roles" "$repo" "$TEAM_DOMAIN" > "$R/$n/node.env"
    put "$n" "$R/$n/node.env" "cn-project/node.env"
    run_on "$n" "chmod +x ~/cn-project/bin/*.sh"
}

echo "== Preparing nodes"
prep mac1 "dns-primary client"
prep mac2 "edge-primary dns-backup client"
prep mac3 "backend edge-standby client"

put mac1 "$R/mac1/dnsmasq.conf" cn-project/dnsmasq/dnsmasq.conf
put mac1 "$R/mac1/teamX.hosts"  cn-project/dnsmasq/teamX.hosts
put mac2 "$R/mac2/dnsmasq.conf" cn-project/dnsmasq/dnsmasq.conf
put mac2 "$R/mac2/teamX.hosts"  cn-project/dnsmasq/teamX.hosts
put mac2 "$R/mac2/nginx-cn-project.conf" cn-project/nginx/cn-project.conf
put mac3 "$R/mac3/nginx-cn-project.conf" cn-project/nginx/cn-project.conf

if [ "$DO_TLS" = 1 ]; then
    echo "== Issuing edge certificate on Mac 2 with its local CA (mkcert)"
    run_on mac2 'export PATH=/opt/homebrew/bin:$PATH; cd ~/cn-project/tls &&
        mkcert -cert-file app.teamX.test.crt -key-file app.teamX.test.key app.teamX.test api.teamX.test 2>&1 | tail -2 &&
        cp "$(mkcert -CAROOT)/rootCA.pem" teamX-root-ca.crt && chmod 600 app.teamX.test.key'
    get mac2 cn-project/tls/app.teamX.test.crt "$ROOT/tls/app.teamX.test.crt"
    get mac2 cn-project/tls/teamX-root-ca.crt  "$ROOT/tls/teamX-root-ca.crt"
    # The standby edge must present the same certificate, so it gets the key too
    # (copied host-to-host over SSH; the key is never committed to git).
    tmpkey="$(mktemp)"; get mac2 cn-project/tls/app.teamX.test.key "$tmpkey"
    put mac3 "$tmpkey" cn-project/tls/app.teamX.test.key; rm -f "$tmpkey"
    put mac3 "$ROOT/tls/app.teamX.test.crt" cn-project/tls/app.teamX.test.crt
    run_on mac3 "chmod 600 ~/cn-project/tls/app.teamX.test.key"
fi
# every node keeps a copy of the CA certificate for curl --cacert / trust setup
for n in mac1 mac2 mac3; do put "$n" "$ROOT/tls/teamX-root-ca.crt" cn-project/tls/teamX-root-ca.crt; done

if [ "$DO_START" = 1 ]; then
    echo "== Starting services"
    run_on mac3 '~/cn-project/bin/cn.sh backend start A; ~/cn-project/bin/cn.sh backend start B'
    run_on mac1 '~/cn-project/bin/cn.sh dns restart'
    run_on mac2 '~/cn-project/bin/cn.sh dns restart; ~/cn-project/bin/cn.sh edge start'
    run_on mac3 '~/cn-project/bin/cn.sh edge start'
    echo "== Status"
    for n in mac1 mac2 mac3; do run_on "$n" '~/cn-project/bin/cn.sh status'; done
fi
