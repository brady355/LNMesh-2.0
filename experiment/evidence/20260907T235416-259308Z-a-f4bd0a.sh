export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
systemctl start bitcoind
timeout 60 bash -c "until bcli getblockchaininfo >/dev/null 2>&1; do sleep 1; done"
systemctl restart lnd
timeout 90 bash -c "until lncli-mesh getinfo >/dev/null 2>&1; do sleep 1; done"
systemctl stop lnmesh-chain-restore.timer