#!/bin/bash
# Helpers to run commands / copy files on team Macs. Source after team/team.env.
# The local Mac is detected by IP, so the same scripts work from any team Mac.

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
LOCAL_IPS=" $(ifconfig 2>/dev/null | awk '/inet /{print $2}' | xargs) "

node_ip()  { local v; v="$(echo "$1" | tr a-z A-Z)_IP";  echo "${!v}"; }
node_ssh() { local v; v="$(echo "$1" | tr a-z A-Z)_SSH"; echo "${!v}"; }
node_dir() { local v; v="$(echo "$1" | tr a-z A-Z)_DIR"; echo "${!v}"; }
is_local() { [[ "$LOCAL_IPS" == *" $(node_ip "$1") "* ]]; }

run_on() {  # run_on <node> <shell command>
    local n="$1"; shift
    if is_local "$n"; then bash -c "$*"; else ssh "${SSH_OPTS[@]}" "$(node_ssh "$n")" "$*"; fi
}
put() {     # put <node> <local file> <path relative to remote $HOME>
    if is_local "$1"; then mkdir -p "$(dirname "$HOME/$3")"; cp "$2" "$HOME/$3"
    else scp -q "${SSH_OPTS[@]}" "$2" "$(node_ssh "$1"):$3"; fi
}
get() {     # get <node> <path relative to remote $HOME> <local file>
    if is_local "$1"; then cp "$HOME/$2" "$3"
    else scp -q "${SSH_OPTS[@]}" "$(node_ssh "$1"):$2" "$3"; fi
}
