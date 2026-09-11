#!/bin/bash
# Phase 5.2-5.3: lnd.conf, wait script, unit, lncli-mesh wrapper, start.
# Usage: 05-lnd-config.sh <letter a|b|c> <mesh-ip> <bitcoind|neutrino> [rpc-password]
# Deploy: ssh lnmesh-a "sudo bash -s a 10.10.0.1 bitcoind $BTC_RPC_PASS" < scripts/common/05-lnd-config.sh
# A uses bitcoind directly. B and C use Neutrino with A as their only peer,
# so payments never need a live RPC call to A (see Demo 5 finding).
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
L="$1"; MESH_IP="$2"; BACKEND="${3:-bitcoind}"; RPCPASS="${4:-${BTC_RPC_PASS:-}}"
[ "$BACKEND" = bitcoind ] && [ -z "$RPCPASS" ] && { echo "bitcoind backend needs the RPC password as 4th arg (BTC_RPC_PASS from hosts.env)"; exit 1; }
{
cat <<EOF
[Application Options]
alias=lnmesh-$L
listen=$MESH_IP:9735
externalip=$MESH_IP
rpclisten=127.0.0.1:10009
restlisten=127.0.0.1:8080
noseedbackup=true
debuglevel=info

[Bitcoin]
bitcoin.regtest=true
bitcoin.node=$BACKEND
bitcoin.defaultremotedelay=1008
EOF
if [ "$BACKEND" = bitcoind ]; then cat <<EOF

[Bitcoind]
bitcoind.rpchost=10.10.0.1:18443
bitcoind.rpcuser=lnmesh
bitcoind.rpcpass=$RPCPASS
bitcoind.zmqpubrawblock=tcp://10.10.0.1:28332
bitcoind.zmqpubrawtx=tcp://10.10.0.1:28333
EOF
else cat <<EOF

[neutrino]
neutrino.connect=10.10.0.1:18444
EOF
fi
} > /etc/lnd/lnd.conf
chown root:lnd /etc/lnd/lnd.conf; chmod 640 /etc/lnd/lnd.conf
if [ "$BACKEND" = bitcoind ]; then
cat > /usr/local/sbin/lnmesh-wait-bitcoind.sh <<'EOF'
#!/bin/bash
# block until A's bitcoind RPC port answers over the mesh
until bash -c 'exec 3<>/dev/tcp/10.10.0.1/18443' 2>/dev/null; do sleep 2; done
EOF
else
cat > /usr/local/sbin/lnmesh-wait-bitcoind.sh <<'EOF'
#!/bin/bash
# wait up to 60 s for A's P2P port over the mesh, then start regardless:
# an offline node must run even when the gateway is down
for i in $(seq 1 30); do bash -c 'exec 3<>/dev/tcp/10.10.0.1/18444' 2>/dev/null && exit 0; sleep 2; done
exit 0
EOF
fi
chmod 755 /usr/local/sbin/lnmesh-wait-bitcoind.sh
if [ "$L" = a ]; then extra="bitcoind.service"; else extra=""; fi
sed "s/__AFTER_EXTRA__/$extra/" /tmp/lnd.service > /etc/systemd/system/lnd.service
[ "$L" = a ] && sed -i 's/^Requires=lnmesh-mesh.service$/Requires=lnmesh-mesh.service\nWants=bitcoind.service/' /etc/systemd/system/lnd.service
cat > /usr/local/bin/lncli-mesh <<'EOF'
#!/bin/bash
exec sudo -u lnd /usr/local/bin/lncli --lnddir=/var/lib/lnd --network=regtest "$@"
EOF
chmod 755 /usr/local/bin/lncli-mesh
systemctl daemon-reload
systemctl enable lnd >/dev/null 2>&1
systemctl restart lnd
for i in $(seq 1 90); do lncli-mesh getinfo 2>/dev/null | jq -e .synced_to_chain >/dev/null 2>&1 && break; sleep 2; done
systemctl is-active lnd
grep -E '^bitcoin.node|^neutrino' /etc/lnd/lnd.conf | tr '\n' ' '; echo; grep '^Restart' /etc/systemd/system/lnd.service
lncli-mesh getinfo | jq -c '{alias, synced_to_chain, block_height, num_active_channels}'
