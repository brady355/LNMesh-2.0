#!/bin/bash
# Bring up wlan0 as an IBSS cell and attach it to batman-adv as bat0.
# Usage: lnmesh-mesh.sh <mesh-ip> [iface]
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MESH_IP="$1"
IFACE="${2:-wlan0}"
SSID=lnmesh
FREQ=2412                     # channel 1
BSSID=02:CA:FE:00:00:01       # fixed cell id: prevents IBSS partitioning

modprobe batman-adv
rfkill unblock wlan
ip link set "$IFACE" down
iw dev "$IFACE" set type ibss
ip link set "$IFACE" up
iw dev "$IFACE" set power_save off || true
iw dev "$IFACE" ibss leave 2>/dev/null || true
iw dev "$IFACE" ibss join "$SSID" "$FREQ" fixed-freq "$BSSID"
batctl if add "$IFACE"
ip link set bat0 up
ip addr replace "${MESH_IP}/24" dev bat0
