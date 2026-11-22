#!/bin/bash
# cn.sh - per-node service control for the CN project (no sudo needed).
#
# Lives in ~/cn-project/bin/cn.sh on every Mac (copied there by scripts/deploy.sh).
#
#   cn.sh dns start|stop|restart|reload|status     dnsmasq (Mac 1 primary, Mac 2 backup)
#   cn.sh dns-record <ip>                           point app/api.teamX.test at <ip> and reload
#   cn.sh edge start|stop|reload|status             nginx edge (Mac 2 primary, Mac 3 standby)
#   cn.sh backend start|stop|status A|B             Flask backends (Mac 3/4)
#   cn.sh status                                    everything on this node
set -uo pipefail
CN_HOME="${CN_HOME:-$HOME/cn-project}"
[ -f "$CN_HOME/node.env" ] && source "$CN_HOME/node.env"
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
DNSMASQ=/opt/homebrew/sbin/dnsmasq
NGINX=/opt/homebrew/bin/nginx
NGINX_SITE=/opt/homebrew/etc/nginx/servers/cn-project.conf
mkdir -p "$CN_HOME"/{logs,run,backup}

ts()  { date '+%H:%M:%S'; }
say() { echo "[$(ts) $(hostname -s)] $*"; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
listener() { lsof -t -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1 | grep .; }

# ---------------------------------------------------------------- DNS
dns() {
    local pid="$CN_HOME/run/dnsmasq.pid"
    case "${1:-status}" in
    start)
        if alive "$pid"; then say "dnsmasq already running (pid $(cat "$pid"))"; return 0; fi
        "$DNSMASQ" --test --conf-file="$CN_HOME/dnsmasq/dnsmasq.conf" >/dev/null 2>&1 \
            || { say "dnsmasq config test FAILED"; "$DNSMASQ" --test --conf-file="$CN_HOME/dnsmasq/dnsmasq.conf"; return 1; }
        "$DNSMASQ" --conf-file="$CN_HOME/dnsmasq/dnsmasq.conf" && sleep 0.5
        alive "$pid" && say "dnsmasq STARTED (pid $(cat "$pid")) on udp/tcp 53" || { say "dnsmasq failed to start"; tail -5 "$CN_HOME/logs/dnsmasq.log"; return 1; } ;;
    stop)
        if alive "$pid"; then kill "$(cat "$pid")"; sleep 0.3; say "dnsmasq STOPPED"; else say "dnsmasq not running"; fi
        rm -f "$pid" ;;
    restart) dns stop; dns start ;;
    reload)
        alive "$pid" || { say "dnsmasq not running"; return 1; }
        kill -HUP "$(cat "$pid")"; say "dnsmasq RELOADED records (SIGHUP: re-read teamX.hosts, cache cleared)" ;;
    status)
        if alive "$pid"; then say "dnsmasq UP (pid $(cat "$pid")) records: $(grep -v '^#' "$CN_HOME/dnsmasq/teamX.hosts" | xargs)"
        else say "dnsmasq DOWN"; fi ;;
    *) echo "usage: cn.sh dns start|stop|restart|reload|status"; return 2 ;;
    esac
}

dns_record() {
    local ip="${1:?usage: cn.sh dns-record <ip>}" f="$CN_HOME/dnsmasq/teamX.hosts"
    local domain="${TEAM_DOMAIN:-teamX.test}"
    { grep '^#' "$f"; echo "$ip app.$domain api.$domain"; } > "$f.new" && mv "$f.new" "$f"
    say "record app.$domain/api.$domain -> $ip"
    dns reload
}

# ---------------------------------------------------------------- EDGE
edge() {
    case "${1:-status}" in
    start)
        brew services stop nginx >/dev/null 2>&1 || true   # we manage nginx directly
        if [ -f "$NGINX_SITE" ] && ! cmp -s "$NGINX_SITE" "$CN_HOME/nginx/cn-project.conf" \
           && [ ! -f "$CN_HOME/backup/cn-project.conf.orig" ]; then
            cp "$NGINX_SITE" "$CN_HOME/backup/cn-project.conf.orig"
            say "backed up previous nginx site config to $CN_HOME/backup/cn-project.conf.orig"
        fi
        mkdir -p "$(dirname "$NGINX_SITE")"
        cp "$CN_HOME/nginx/cn-project.conf" "$NGINX_SITE"
        "$NGINX" -t 2>&1 | grep -v 'the "user" directive' || true
        "$NGINX" -t >/dev/null 2>&1 || { say "nginx config test FAILED"; return 1; }
        if pgrep -qx nginx; then "$NGINX" -s reload; say "nginx RELOADED"
        else "$NGINX" && say "nginx STARTED (ports 80, 443)"; fi ;;
    stop)
        if pgrep -qx nginx; then "$NGINX" -s stop 2>/dev/null || pkill -x nginx; sleep 0.5; say "nginx STOPPED"
        else say "nginx not running"; fi ;;
    reload) edge start ;;
    status)
        if pgrep -qx nginx; then say "nginx UP: $(lsof -nP -a -c nginx -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | sort -u | xargs)"
        else say "nginx DOWN"; fi ;;
    *) echo "usage: cn.sh edge start|stop|reload|status"; return 2 ;;
    esac
}

# ---------------------------------------------------------------- BACKENDS
backend() {
    local action="${1:-status}" id="${2:-}"
    if [ -z "$id" ]; then for b in A B; do backend "$action" "$b"; done; return; fi
    local port; case "$id" in A) port=3001 ;; B) port=3002 ;; *) echo "backend id must be A or B"; return 2 ;; esac
    local pid="$CN_HOME/run/backend-$id.pid"
    case "$action" in
    start)
        if listener "$port" >/dev/null; then say "backend $id already running on :$port"; return 0; fi
        local repo="${CN_REPO:?CN_REPO not set in node.env}"
        ( cd "$repo/backend" && BACKEND_ID="$id" PORT="$port" nohup .venv/bin/python app.py \
            >> "$CN_HOME/logs/backend-$id.log" 2>&1 & disown )
        for _ in 1 2 3 4 5 6 7 8 9 10; do listener "$port" >/dev/null && break; sleep 0.3; done
        # macOS framework Python re-execs itself, so track the process that LISTENS on the port.
        if listener "$port" > "$pid"; then say "backend $id STARTED on 0.0.0.0:$port (pid $(cat "$pid"))"
        else say "backend $id failed"; tail -5 "$CN_HOME/logs/backend-$id.log"; fi ;;
    stop)
        local p; p="$(listener "$port")"
        if [ -n "$p" ]; then kill $p; for _ in 1 2 3 4 5 6 7 8 9 10; do listener "$port" >/dev/null || break; sleep 0.2; done
            say "backend $id STOPPED (port $port closed)"; else say "backend $id not running"; fi
        rm -f "$pid" ;;
    status)
        local p; p="$(listener "$port")"
        if [ -n "$p" ]; then say "backend $id UP on :$port (pid $p)"; else say "backend $id DOWN"; fi ;;
    *) echo "usage: cn.sh backend start|stop|status A|B"; return 2 ;;
    esac
}

case "${1:-status}" in
    dns) shift; dns "$@" ;;
    dns-record) shift; dns_record "$@" ;;
    edge) shift; edge "$@" ;;
    backend) shift; backend "$@" ;;
    status)
        say "node=${NODE:-?} roles=${ROLES:-?}"
        [ -f "$CN_HOME/dnsmasq/dnsmasq.conf" ] && dns status
        [ -f "$CN_HOME/nginx/cn-project.conf" ] && edge status
        [[ "${ROLES:-}" == *backend* ]] && backend status
        true ;;
    *) sed -n '2,12p' "$0"; exit 2 ;;
esac
