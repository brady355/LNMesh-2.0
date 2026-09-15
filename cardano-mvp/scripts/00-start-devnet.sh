#!/usr/bin/env bash
# Runs on the gateway. Starts a fresh single-node Cardano devnet from the
# static cardano-node 11.0.1 arm64 release and the Hydra 2.4.1 devnet genesis.
# The devnet uses network magic 42, one pool with all the stake and the Conway
# era. The script then publishes the node socket on TCP port 3333 for the
# leaves. The slot length stays at the mainnet value of 1 s, because
# hydra-node converts the grace time of a deposit into a slot count, so longer
# slots would delay every deposit by minutes. The active slot coefficient is
# 0.1, twice the mainnet value, so a block arrives every 10 s on average.
# hydra-node bounds the validity of its close, contest and fanout transactions
# by the contestation period. With 60 s periods and mainnet block gaps those
# transactions expired in the mempool about once in twenty times, so the devnet
# produces blocks at twice the mainnet rate. The epoch length grows from 5
# slots to 1000 slots, so no epoch stays without a block. The script wipes any
# previous devnet, so run 01-setup-and-distribute.sh again afterwards.
#   00-start-devnet.sh [slotSeconds] [activeSlotsCoeff] [epochSlots]
set -euo pipefail
. "$HOME/testbed.env"
A=$HOME/lnmesh-ada; B=$A/bin; SRC=$A/hydra-src
SLOT=${1:-1}; COEFF=${2:-0.1}; EPOCH=${3:-1000}
CARDANO_TGZ=https://github.com/IntersectMBO/cardano-node/releases/download/11.0.1/cardano-node-11.0.1-linux-arm64.tar.gz
cd "$A"; mkdir -p logs bin

pkill -f '[c]ardano-node run' || true
pkill -f '[s]ockfwd.py tcp2unix' || true
sleep 1

if [ ! -x cardano/bin/cardano-node ]; then
  mkdir -p cardano; cd cardano
  [ -f cardano-node-11.0.1-linux-arm64.tar.gz ] || curl -sL -o cardano-node-11.0.1-linux-arm64.tar.gz $CARDANO_TGZ
  tar xzf cardano-node-11.0.1-linux-arm64.tar.gz; cd "$A"
fi
for b in cardano-node cardano-cli cardano-submit-api; do ln -sf "$A/cardano/bin/$b" "$B/$b"; done
[ -d "$SRC" ] || git clone -q --depth 1 --branch 2.4.1 https://github.com/cardano-scaling/hydra.git "$SRC"

rm -rf devnet hydra-scripts.txid
cp -a "$SRC/hydra-cluster/config/devnet" devnet; chmod -R u+w devnet
cp -a "$SRC/hydra-cluster/config/credentials" devnet/credentials; chmod -R u+w devnet/credentials
echo '{"localRoots": [], "publicRoots": []}' > devnet/topology.json
sed -i "s/\"startTime\": [0-9]*/\"startTime\": $(date +%s)/" devnet/genesis-byron.json
sed -i "s/\"slotDuration\": \"[0-9]*\"/\"slotDuration\": \"$((SLOT * 1000))\"/" devnet/genesis-byron.json
sed -i "s/\"systemStart\": \".*\"/\"systemStart\": \"$(date -u +%FT%TZ)\"/" devnet/genesis-shelley.json
sed -i "s/\"slotLength\": [0-9.]*/\"slotLength\": $SLOT/" devnet/genesis-shelley.json
sed -i "s/\"activeSlotsCoeff\": [0-9.]*/\"activeSlotsCoeff\": $COEFF/" devnet/genesis-shelley.json
sed -i "s/\"epochLength\": [0-9]*/\"epochLength\": $EPOCH/" devnet/genesis-shelley.json
grep -E '"slotLength"|"activeSlotsCoeff"|"epochLength"' devnet/genesis-shelley.json | tr -d ' \n'; echo
find devnet -name '*.skey' -exec chmod 0400 {} \;

: > logs/cardano-node.log
setsid -f bash -c "exec $B/cardano-node run --config $A/devnet/cardano-node.json --topology $A/devnet/topology.json \
  --database-path $A/devnet/db --socket-path $A/devnet/node.socket \
  --shelley-kes-key $A/devnet/kes.skey --shelley-vrf-key $A/devnet/vrf.skey \
  --shelley-operational-certificate $A/devnet/opcert.cert \
  --byron-delegation-certificate $A/devnet/byron-delegation.cert --byron-signing-key $A/devnet/byron-delegate.key \
  >> $A/logs/cardano-node.log 2>&1 < /dev/null"
export CARDANO_NODE_SOCKET_PATH=$A/devnet/node.socket
echo "waiting for the node socket and the first block..."
for i in $(seq 120); do
  [ -S devnet/node.socket ] && $B/cardano-cli conway query tip --testnet-magic 42 2>/dev/null | grep -q '"block"' && break
  sleep 1
done
setsid -f bash -c "exec python3 $A/sockfwd.py tcp2unix 0.0.0.0:3333 $A/devnet/node.socket >> $A/logs/sockfwd.log 2>&1 < /dev/null"
sleep 2
$B/cardano-cli conway query tip --testnet-magic 42
echo "node socket for the leaves: tcp://$GW_IP:3333, slot ${SLOT} s, active slot coefficient ${COEFF}"
