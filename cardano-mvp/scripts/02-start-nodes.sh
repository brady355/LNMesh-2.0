#!/usr/bin/env bash
# Runs on the gateway. Starts or restarts the socket forwarder, hydra-node and
# hydrapay on the leaves, and the mirror hydra-nodes with their observers on
# the gateway.
#   TOWER=1 CP=60 02-start-nodes.sh [pi2|pi3|pi2m|pi3m|mirrors|all]
# CP is the contestation period, DP the deposit period, DA the deposit
# activation and US the unsynced period, all in seconds. Every member of the
# head must use the same values. hydra-node gives a deposit transaction a
# validity window of min(DP / 2, 200 s), and the end of that window becomes
# the creation time of the deposit. The deposit becomes active DA later, and
# only then does a snapshot carry it and an increment transaction claim it.
# The increment transaction gets a validity window of min(CP, 200 s), and the
# deposit validator rejects it when that window reaches past the deposit
# deadline minus DP (error D01). Thus DP must cover the creation delay, DA, a
# few block intervals and CP, and the default is CP plus 300 s. hydra-node
# refuses payments once it has seen no block for the unsynced period. Its
# default of CP / 2 is shorter than a normal block gap on this chain when CP is
# 60 s, so the default US here is 300 s.
# TOWER=1 puts the two mirror nodes of the gateway into every peer list and
# starts them. A mirror runs with the Hydra key and the Cardano node key of its
# leaf, so it signs snapshots and contests for the leaf. TOWER=0 stops the
# mirrors, so the leaves peer with each other only.
# Ports: the Hydra network uses 5001 on the leaves and 5002 and 5003 for the
# mirrors. The hydra-node API uses 4001 on a leaf and 4002 and 4003 for the
# mirrors, all bound to localhost. The hydrapay control port uses 7200 on a
# leaf and 7202 and 7203 for the observers. The Ethereum arm uses 6000, 6500
# and 7000 and the XRP arm 6100, 6600 and 7100, so all three arms can stay up
# at the same time.
set -uo pipefail
. "$HOME/testbed.env"
A=$HOME/lnmesh-ada
CP=${CP:-60}; DP=${DP:-$((CP + 300))}; DA=${DA:-15}; US=${US:-300}
TOWER=${TOWER:-1}
TXID=$(cat "$A/hydra-scripts.txid")
COMMON="--hydra-scripts-tx-id $TXID --ledger-protocol-parameters protocol-parameters.json --testnet-magic 42 --contestation-period ${CP}s --deposit-period ${DP}s --deposit-activation ${DA}s --unsynced-period ${US}s ${HYDRA_EXTRA:-}"

peers() { # name: every other member of the Hydra network
  local me=$1 p=""
  [ "$me" != pi2 ] && p="$p --peer $PI2_IP:5001"
  [ "$me" != pi3 ] && p="$p --peer $PI3_IP:5001"
  if [ "$TOWER" = 1 ]; then
    [ "$me" != pi2m ] && p="$p --peer $GW_IP:5002"
    [ "$me" != pi3m ] && p="$p --peer $GW_IP:5003"
  fi
  echo "$p"
}

start_leaf() { # name peer
  local me=$1 peer=$2 ip P
  ip=$(leaf_ip "$me")
  P=$(peers "$me")
  on_leaf "$me" "pkill -f '[h]ydrapay.py node'; pkill -f '[h]ydra-node-exe'; pkill -f '[s]ockfwd.py unix2tcp'; sleep 1"
  on_leaf "$me" "cd ~/lnmesh-ada && setsid -f bash -c 'exec python3 sockfwd.py unix2tcp \$HOME/lnmesh-ada/node.socket $GW_IP:3333 >> sockfwd.log 2>&1 < /dev/null'"
  on_leaf "$me" "cd ~/lnmesh-ada && setsid -f bash -c 'exec bin/hydra-node --node-id $me --listen $ip:5001 $P \
    --api-host 127.0.0.1 --api-port 4001 --monitoring-port 6001 \
    --hydra-signing-key keys/$me-hydra.sk --hydra-verification-key keys/$peer-hydra.vk \
    --cardano-signing-key keys/$me-node.sk --cardano-verification-key keys/$peer-node.vk \
    --node-socket node.socket --persistence-dir persistence $COMMON >> hydra-node.log 2>&1 < /dev/null'"
  on_leaf "$me" 'for i in $(seq 60); do curl -s -m 2 127.0.0.1:4001/head >/dev/null && break; sleep 1; done; curl -s -m 2 127.0.0.1:4001/head | cut -c1-80; echo'
  on_leaf "$me" "cd ~/lnmesh-ada && setsid -f bash -c 'exec venv/bin/python hydrapay.py node -api 127.0.0.1:4001 -skey keys/$me-funds.sk \
    -peer-vkey keys/$peer-funds.vk -cardano-cli bin/cardano-cli -socket node.socket \
    -magic 42 -ctl 127.0.0.1:7200 -workdir . >> node.log 2>&1 < /dev/null'; sleep 2; tail -1 ~/lnmesh-ada/node.log"
}

stop_mirror() { # name
  pkill -f "[h]ydra-node-exe.*--node-id $1m"; pkill -f "[h]ydrapay.py node -api 127.0.0.1:400${1#pi}"; sleep 1
}

start_mirror() { # name peer port apiport ctlport
  local me=$1 peer=$2 port=$3 api=$4 ctl=$5 P
  stop_mirror "$me"
  [ "$TOWER" = 1 ] || { echo "mirror of $me stopped"; return; }
  P=$(peers "${me}m")
  mkdir -p "$A/mirror-$me" "$A/logs"
  ( cd "$A" && setsid -f bash -c "exec bin/hydra-node --node-id ${me}m --listen 0.0.0.0:$port --advertise $GW_IP:$port $P \
    --api-host 127.0.0.1 --api-port $api \
    --hydra-signing-key keys/$me-hydra.sk --hydra-verification-key keys/$peer-hydra.vk \
    --cardano-signing-key keys/$me-node.sk --cardano-verification-key keys/$peer-node.vk \
    --node-socket devnet/node.socket --persistence-dir mirror-$me $COMMON >> logs/mirror-$me.log 2>&1 < /dev/null" )
  for i in $(seq 60); do curl -s -m 2 "127.0.0.1:$api/head" >/dev/null && break; sleep 1; done
  printf 'mirror of %s: ' "$me"; curl -s -m 2 "127.0.0.1:$api/head" | cut -c1-60; echo
  ( cd "$A" && setsid -f bash -c "exec venv/bin/python hydrapay.py node -api 127.0.0.1:$api -ctl 127.0.0.1:$ctl -workdir mirror-$me >> logs/mirror-$me-observer.log 2>&1 < /dev/null" )
}

case "${1:-all}" in
  pi2) start_leaf pi2 pi3 ;;
  pi3) start_leaf pi3 pi2 ;;
  pi2m) start_mirror pi2 pi3 5002 4002 7202 ;;
  pi3m) start_mirror pi3 pi2 5003 4003 7203 ;;
  mirrors) start_mirror pi2 pi3 5002 4002 7202; start_mirror pi3 pi2 5003 4003 7203 ;;
  all) start_mirror pi2 pi3 5002 4002 7202; start_mirror pi3 pi2 5003 4003 7203; start_leaf pi2 pi3; start_leaf pi3 pi2 ;;
  *) echo "usage: TOWER=0|1 CP=60 $0 [pi2|pi3|pi2m|pi3m|mirrors|all]"; exit 2 ;;
esac
