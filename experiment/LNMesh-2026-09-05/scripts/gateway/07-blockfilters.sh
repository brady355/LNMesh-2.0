#!/bin/bash
# Enable compact block filters and P2P on the mesh so B and C can run Neutrino
# with A as their only peer.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
C=/var/lib/bitcoind/bitcoin.conf
grep -q '^blockfilterindex=1' $C || sed -i 's/^txindex=1$/txindex=1\nblockfilterindex=1\npeerblockfilters=1\nlisten=1/' $C
grep -q '^bind=10.10.0.1' $C || sed -i 's/^rpcbind=127.0.0.1$/bind=127.0.0.1\nbind=10.10.0.1\nwhitelist=10.10.0.0\/24\nrpcbind=127.0.0.1/' $C
systemctl restart bitcoind
for i in $(seq 1 30); do bcli getblockchaininfo >/dev/null 2>&1 && break; sleep 1; done
sleep 3
bcli getindexinfo | jq -c .
ss -ltnp | grep -E ':18444' | awk '{print $4}'
