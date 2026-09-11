#!/bin/bash
# Phase 2: install mesh script + unit. Run as root. Expects MESH_IP, and the
# two files appended after a marker by the deploy wrapper.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MESH_IP="$1"
install -m 755 /tmp/lnmesh-mesh.sh /usr/local/sbin/lnmesh-mesh.sh
sed "s/__MESH_IP__/$MESH_IP/" /tmp/lnmesh-mesh.service > /etc/systemd/system/lnmesh-mesh.service
systemctl daemon-reload
systemctl enable lnmesh-mesh >/dev/null 2>&1
systemctl restart lnmesh-mesh
sleep 2
systemctl is-active lnmesh-mesh
ip -br addr show bat0
iw dev wlan0 info | grep -E 'type|ssid|channel'
