#!/usr/bin/env bash
# Runs on the gateway. Shared helpers of the Cardano experiment scripts, which
# source this file after testbed.env.
A=$HOME/lnmesh-ada; C=$A/ctl.sh; S=$A/02-start-nodes.sh; L=$A/logs
export CARDANO_NODE_SOCKET_PATH=$A/devnet/node.socket

# onchain prints the funds of both leaves on layer 1.
onchain() {
  local n
  for n in pi2 pi3; do
    printf '%s %s funds on L1: ' "$(ts)" $n
    "$A/bin/cardano-cli" conway query utxo --address "$(cat "$A/keys/$n-funds.addr")" --testnet-magic 42 --out-file /dev/stdout | jq -r '[.[].value.lovelace] | add // 0 | . / 1000000'
  done
}

# deposit runs the deposit of one leaf and retries once, because an expired
# deposit comes back to layer 1 on its own.
deposit() {
  local out
  out=$($C "$1" deposit); echo "$out"
  echo "$out" | grep -q '^OK' || { echo "[$(ts)] retrying the deposit of $1"; sleep 5; $C "$1" deposit; }
}

# reset_all stops every hydra-node and hydrapay, wipes the head state on the
# leaves and the mirrors, and merges the funds of each leaf into one output.
reset_all() {
  on_leaf pi2 "pkill -f '[h]ydra-node-exe'; pkill -f '[h]ydrapay.py node'; rm -rf ~/lnmesh-ada/persistence ~/lnmesh-ada/persistence.snap0"
  on_leaf pi3 "pkill -f '[h]ydra-node-exe'; pkill -f '[h]ydrapay.py node'; rm -rf ~/lnmesh-ada/persistence"
  pkill -f '[h]ydra-node-exe.*--node-id pi[23]m'; pkill -f '[h]ydrapay.py node -api 127.0.0.1:400[23]'; sleep 1
  rm -rf "$A/mirror-pi2" "$A/mirror-pi3"
  bash "$A/consolidate.sh"
}
