#!/bin/bash
# Phase 3 on A: serve time to the mesh.
set -euo pipefail
cat > /etc/chrony/conf.d/lnmesh.conf <<'EOF'
allow 10.10.0.0/24
local stratum 10
EOF
systemctl restart chrony
sleep 3
chronyc tracking | grep -E 'Reference ID|Stratum|System time'
