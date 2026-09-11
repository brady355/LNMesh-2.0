export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
test -f /var/backups/lnmesh/initial/chrony.conf || cp -a /etc/chrony/chrony.conf /var/backups/lnmesh/initial/chrony.conf
if test "$(hostname)" = pi1gateway; then
  cp /var/backups/lnmesh/initial/chrony.conf /etc/chrony/chrony.conf
  printf '\nallow 10.10.0.0/24\n' >> /etc/chrony/chrony.conf
else
  cat > /etc/chrony/chrony.conf <<'EOF'
server 10.10.0.1 iburst minpoll 4 maxpoll 6
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
fi
install -d /etc/systemd/system/chrony.service.d
cat > /etc/systemd/system/chrony.service.d/lnmesh.conf <<'EOF'
[Unit]
After=lnmesh-mesh.service
Requires=lnmesh-mesh.service
EOF
systemctl daemon-reload
systemctl restart chrony
chronyc waitsync 30 0.1 0 2
chronyc -n tracking
chronyc -n sources -v
date --iso-8601=ns --utc
