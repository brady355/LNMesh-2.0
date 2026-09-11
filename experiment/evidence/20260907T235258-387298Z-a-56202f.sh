export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
systemd-run --unit=lnmesh-chain-restore --on-active=5min /bin/bash -c 'systemctl start bitcoind; systemctl restart lnd'
systemctl stop bitcoind
test "$(systemctl is-active bitcoind || true)" = inactive
date --iso-8601=ns --utc