#!/bin/bash
# Phase 6.1 on A: never route traffic between eth0 and bat0.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cat > /etc/sysctl.d/99-lnmesh-noforward.conf <<'EOF'
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
EOF
sysctl --system >/dev/null
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
echo "nft rules mentioning masquerade/forward: $(nft list ruleset 2>/dev/null | grep -ciE 'masquerade|hook forward' || true)"
echo "nft ruleset lines total: $(nft list ruleset 2>/dev/null | wc -l)"
