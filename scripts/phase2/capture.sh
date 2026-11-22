#!/bin/bash
# Packet captures for the evidence folder (no sudo: the team is in the access_bpf group).
#
#   scripts/phase2/capture.sh flow      Phase 1 Task G: DNS -> TCP -> TLS 1.2 -> HTTP across the LAN
#   scripts/phase2/capture.sh failover  Extension A: client queries primary (ICMP unreachable) then backup
#   scripts/phase2/capture.sh isolation Extension C: capture on the backend Mac while client + edge connect
#
# Output: evidence/phase2/captures/<name>.pcapng plus a tshark summary <name>.txt
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/team/team.env"; source "$ROOT/scripts/lib/remote.sh"
OUT="$ROOT/evidence/phase2/captures"; mkdir -p "$OUT"
TSHARK=/Applications/Wireshark.app/Contents/MacOS/tshark
APP="app.$TEAM_DOMAIN"

start_cap() {  # start_cap <file> <bpf filter>
    tcpdump -i en0 -s 0 -U -w "$1.pcap" "$2" >/dev/null 2>&1 & CAP=$!; sleep 1.5
}
stop_cap() {   # stop_cap <file>
    sleep 1; kill "$CAP" 2>/dev/null; wait "$CAP" 2>/dev/null
    "$TSHARK" -r "$1.pcap" -w "$1.pcapng" -F pcapng 2>/dev/null && rm -f "$1.pcap"
}
summary() {    # summary <file> <display filter> [extra fields...]
    "$TSHARK" -r "$1.pcapng" -Y "$2" -T fields -E separator=' | ' \
        -e frame.number -e frame.time_relative -e ip.src -e srcport -e ip.dst -e dstport -e _ws.col.Protocol -e _ws.col.Info 2>/dev/null \
        | sed 's/| srcport/|/'
}

case "${1:-}" in
flow)
    F="$OUT/phase1-full-flow-lan"
    sudo -n dscacheutil -flushcache 2>/dev/null; sudo -n killall -HUP mDNSResponder 2>/dev/null
    sleep $((DNS_TTL + 1))   # make sure the client must really ask the DNS server
    start_cap "$F" "host $DNS1_IP or host $DNS2_IP or host $EDGE1_IP"
    # one real client request: system resolver -> team DNS, then HTTPS. TLS 1.2 so the
    # Certificate message is visible in clear text (TLS 1.3 encrypts it).
    curl -sv --tlsv1.2 --tls-max 1.2 "https://$APP/api/status" > "$F.curl.txt" 2>&1
    curl -sv --http2 "https://$APP/api/status" >> "$F.curl.txt" 2>&1        # and a TLS 1.3 / HTTP/2 one
    stop_cap "$F"
    {
      echo "# $F.pcapng  ($(date))  client $(ipconfig getifaddr en0)"
      echo "## DNS (filter: dns)";                         "$TSHARK" -r "$F.pcapng" -Y dns -T fields -e frame.number -e ip.src -e udp.srcport -e ip.dst -e udp.dstport -e dns.qry.name -e dns.a -e dns.resp.ttl -E separator=' | '
      echo "## TCP handshakes to 443 (filter: tcp.flags.syn==1)"; "$TSHARK" -r "$F.pcapng" -Y 'tcp.flags.syn==1' -T fields -e frame.number -e tcp.stream -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.flags.str -e tcp.seq_raw -e tcp.ack_raw -E separator=' | '
      echo "## TLS handshake records (filter: tls.handshake)"; "$TSHARK" -r "$F.pcapng" -Y 'tls.handshake or tls.change_cipher_spec' -T fields -e frame.number -e tcp.stream -e ip.src -e ip.dst -e tls.record.version -e _ws.col.Info -e tls.handshake.extensions_server_name -E separator=' | '
      echo "## Encrypted application data (first 6)";     "$TSHARK" -r "$F.pcapng" -Y 'tls.app_data' -T fields -e frame.number -e tcp.stream -e ip.src -e ip.dst -e frame.len -E separator=' | ' | head -6
      echo "## Certificate subject sent by the server";  "$TSHARK" -r "$F.pcapng" -Y 'tls.handshake.type==11' -T fields -e frame.number -e x509sat.uTF8String -e x509ce.dNSName -E separator=' | ' | head -2
    } > "$F.txt"
    cat "$F.txt" ;;
failover)
    F="$OUT/extA-dns-failover"
    start_cap "$F" "port 53 or icmp"
    dig app.$TEAM_DOMAIN +time=2 >/dev/null; sleep 1
    run_on mac1 '~/cn-project/bin/cn.sh dns stop'
    dig app.$TEAM_DOMAIN +time=2 +noall +answer +stats | grep -E 'IN|SERVER'
    run_on mac1 '~/cn-project/bin/cn.sh dns start'
    stop_cap "$F"
    { echo "# $F.pcapng"; "$TSHARK" -r "$F.pcapng" -Y 'dns or icmp' -T fields -e frame.number -e frame.time_relative -e ip.src -e ip.dst -e _ws.col.Protocol -e _ws.col.Info -E separator=' | '; } > "$F.txt"
    cat "$F.txt" ;;
isolation)
    F="$OUT/extC-isolation-backend-side"
    start_cap "$F" "tcp port 3001 or tcp port 3002"
    run_on mac1 "curl -s -m 3 -o /dev/null http://$BACKEND_A/api/status; echo client_exit=\$?"
    run_on mac2 "curl -s -m 3 -o /dev/null -w 'edge: %{http_code}\n' http://$BACKEND_A/api/status"
    stop_cap "$F"
    { echo "# $F.pcapng (captured on the backend Mac)"; "$TSHARK" -r "$F.pcapng" -T fields -e frame.number -e frame.time_relative -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.flags.str -E separator=' | ' | head -30; } > "$F.txt"
    cat "$F.txt" ;;
*) sed -n '2,9p' "$0"; exit 2 ;;
esac
