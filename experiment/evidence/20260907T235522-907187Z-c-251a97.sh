export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
systemctl stop lnd-breach
install -d -m 0700 /var/backups/lnmesh/breach
cp --reflink=auto /var/lib/lnd-breach/data/graph/regtest/channel.db /var/backups/lnmesh/breach/channel.stale.db
sha256sum /var/backups/lnmesh/breach/channel.stale.db
systemctl start lnd-breach
timeout 90 bash -c 'until lncli-breach getinfo >/dev/null 2>&1; do sleep 1; done'