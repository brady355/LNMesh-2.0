set -euo pipefail
test "$(hostname)" = pi1gateway
cat > /etc/sysctl.d/90-lnmesh-no-forward.conf <<'EOF'
net.ipv4.ip_forward=0
net.ipv6.conf.all.forwarding=0
EOF
sysctl -p /etc/sysctl.d/90-lnmesh-no-forward.conf
ip -j route
ip -6 -j route
ss -tnp | grep -E '18444|9735' || true
