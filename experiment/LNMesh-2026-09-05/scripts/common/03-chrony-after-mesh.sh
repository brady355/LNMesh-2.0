#!/bin/bash
# Phase 3 fix: chrony must start after bat0 exists, or its first polls to A
# are lost and it backs off for minutes.
set -euo pipefail
mkdir -p /etc/systemd/system/chrony.service.d
cat > /etc/systemd/system/chrony.service.d/lnmesh.conf <<'EOF'
[Unit]
After=lnmesh-mesh.service
Wants=lnmesh-mesh.service
EOF
systemctl daemon-reload
systemctl cat chrony | grep -A2 lnmesh.conf | tail -2
