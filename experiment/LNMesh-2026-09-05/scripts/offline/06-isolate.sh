#!/bin/bash
# Phase 6.3 on B, C: wired profile off, Bluetooth blocked, then prove isolation.
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
nmcli con mod "Wired connection 1" connection.autoconnect no
nmcli con down "Wired connection 1" >/dev/null 2>&1 || true
rfkill block bluetooth
echo "--- profile: $(nmcli -t -f NAME,AUTOCONNECT con show | grep Wired)  bt: $(rfkill list bluetooth | grep -c 'Soft blocked: yes')/1 blocked"
echo "--- ip -br addr:"; ip -br addr
echo "--- default route: [$(ip route show default)]"
curl -m 5 -sI https://example.com >/dev/null 2>&1; echo "curl example.com exit=$?"
ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; echo "ping 8.8.8.8 exit=$?"
ROUTER="${1:-192.168.0.1}"   # home router, must be unreachable
ping -c1 -W2 $ROUTER >/dev/null 2>&1; echo "ping $ROUTER (home router) exit=$?"
ping -c1 -W2 10.10.0.1 >/dev/null 2>&1; echo "ping 10.10.0.1 exit=$?"
echo "lnd synced: $(lncli-mesh getinfo | jq -c '[.synced_to_chain,.block_height]')"
