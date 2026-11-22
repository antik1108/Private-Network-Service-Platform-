#!/bin/bash
# Task A inventory for THIS Mac: interface, IPv4, mask/prefix, gateway, MAC, DNS servers.
# Run at the start of every session - college Wi-Fi DHCP can hand out new addresses.
IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | grep -v utun | head -1)"; IF="${IF:-en0}"
MASK_HEX="$(ifconfig "$IF" | awk '/inet /{print $4}')"
PREFIX=$(python3 -c "print(bin(int('$MASK_HEX',16)).count('1'))" 2>/dev/null)
echo "Host:        $(hostname -s)"
echo "Interface:   $IF"
echo "IPv4:        $(ipconfig getifaddr "$IF")/$PREFIX  (mask $(ipconfig getoption "$IF" subnet_mask))"
echo "Gateway:     $(ipconfig getoption "$IF" router)"
echo "MAC address: $(ifconfig "$IF" | awk '/ether/{print $2}')"
echo "DNS servers: $(networksetup -getdnsservers Wi-Fi 2>/dev/null | xargs)"
