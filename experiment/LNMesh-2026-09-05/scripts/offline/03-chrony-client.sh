#!/bin/bash
# Phase 3 on B, C: A is the only time source. chrony waits for A to be
# reachable over the mesh before starting (bounded), and polls every
# 16-64 s so a missed burst does not cost minutes.
set -euo pipefail
sed -i 's/^pool /#pool /; s/^server /#server /' /etc/chrony/chrony.conf
mkdir -p /etc/chrony/sources.d /etc/systemd/system/chrony.service.d
echo 'server 10.10.0.1 iburst prefer minpoll 4 maxpoll 6' > /etc/chrony/sources.d/lnmesh.sources
echo 'makestep 1 -1' > /etc/chrony/conf.d/lnmesh.conf
cat > /usr/local/sbin/lnmesh-wait-gateway.sh <<'EOF'
#!/bin/bash
# wait up to 60 s for A over the mesh; never fail, chrony must start regardless
for i in $(seq 1 30); do ping -c1 -W1 10.10.0.1 >/dev/null 2>&1 && exit 0; sleep 2; done
exit 0
EOF
chmod 755 /usr/local/sbin/lnmesh-wait-gateway.sh
cat > /etc/systemd/system/chrony.service.d/lnmesh.conf <<'EOF'
[Unit]
After=lnmesh-mesh.service
Wants=lnmesh-mesh.service

[Service]
ExecStartPre=/usr/local/sbin/lnmesh-wait-gateway.sh
EOF
systemctl daemon-reload
systemctl restart chrony
sleep 8
chronyc sources
