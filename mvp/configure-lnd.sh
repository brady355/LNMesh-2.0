#!/bin/bash
# Write lnd.conf and unit. Usage: sudo bash -s <a|b|c> <bitcoind|neutrino> < configure-lnd.sh
# bitcoind: local Bitcoin Core on loopback. neutrino: light client with the gateway as only peer.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
L="$1"; BACKEND="${2:-bitcoind}"
case "$L" in a) IP=10.10.0.1;; b) IP=10.10.0.2;; c) IP=10.10.0.3;; *) echo "usage"; exit 1;; esac
{
cat <<CONF
[Application Options]
alias=lnmesh-$L
listen=$IP:9735
externalip=$IP
rpclisten=127.0.0.1:10009
restlisten=127.0.0.1:8080
noseedbackup=true
debuglevel=info

[Bitcoin]
bitcoin.regtest=true
bitcoin.node=$BACKEND
bitcoin.defaultremotedelay=1008
CONF
if [ "$BACKEND" = bitcoind ]; then
  source /etc/lnmesh/rpcauth.env
  cat <<CONF

[Bitcoind]
bitcoind.rpchost=127.0.0.1:18443
bitcoind.rpcuser=$RPC_USER
bitcoind.rpcpass=$RPC_PASS
bitcoind.zmqpubrawblock=tcp://127.0.0.1:28332
bitcoind.zmqpubrawtx=tcp://127.0.0.1:28333
CONF
else
  cat <<CONF

[neutrino]
neutrino.connect=10.10.0.1:18444
CONF
fi
} > /etc/lnd/lnd.conf
chown root:lnd /etc/lnd/lnd.conf; chmod 640 /etc/lnd/lnd.conf
if [ "$BACKEND" = bitcoind ]; then
  printf '%s\n' '#!/bin/bash' 'until bash -c "exec 3<>/dev/tcp/127.0.0.1/18443" 2>/dev/null; do sleep 2; done' > /usr/local/sbin/lnmesh-wait-bitcoind.sh
  AFTER="bitcoind.service"; WANTS="Wants=bitcoind.service"
else
  printf '%s\n' '#!/bin/bash' 'for i in $(seq 1 30); do bash -c "exec 3<>/dev/tcp/10.10.0.1/18444" 2>/dev/null && exit 0; sleep 2; done; exit 0' > /usr/local/sbin/lnmesh-wait-bitcoind.sh
  AFTER=""; WANTS=""
fi
chmod 755 /usr/local/sbin/lnmesh-wait-bitcoind.sh
cat > /etc/systemd/system/lnd.service <<UNIT
[Unit]
Description=LND for LNMesh
Requires=lnmesh-mesh.service
$WANTS
After=lnmesh-mesh.service chrony.service $AFTER

[Service]
User=lnd
Group=lnd
ExecStartPre=/usr/local/sbin/lnmesh-wait-bitcoind.sh
ExecStart=/usr/local/bin/lnd --lnddir=/var/lib/lnd --configfile=/etc/lnd/lnd.conf
Restart=always
RestartSec=5
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload; systemctl enable lnd >/dev/null 2>&1; systemctl restart lnd
for i in $(seq 1 90); do lncli-mesh getinfo 2>/dev/null | jq -e .synced_to_chain >/dev/null 2>&1 && break; sleep 2; done
echo "$L lnd=$(systemctl is-active lnd) backend=$BACKEND $(lncli-mesh getinfo | jq -c '{synced_to_chain, block_height}')"
