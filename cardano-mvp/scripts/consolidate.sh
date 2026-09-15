#!/usr/bin/env bash
# Runs on the gateway. Merges the UTxOs of the funds address of each leaf into
# one output on layer 1. Every fanout leaves one output per received payment at
# the funds address, and the ledger rejected a deposit that spent many small
# outputs at submission. Therefore the experiment scripts call this script
# before they open a head. The gateway generated the funds keys and keeps them
# under keys/, and this testbed convenience relies on that. Nothing changes
# when an address already holds one output.
set -uo pipefail
. "$HOME/testbed.env"
A=$HOME/lnmesh-ada; M=42
export CARDANO_NODE_SOCKET_PATH=$A/devnet/node.socket
CLI="$A/bin/cardano-cli conway"
for n in pi2 pi3; do
  addr=$(cat "$A/keys/$n-funds.addr")
  utxo=$($CLI query utxo --address "$addr" --testnet-magic $M --out-file /dev/stdout)
  count=$(echo "$utxo" | jq 'length')
  [ "$count" -le 1 ] && { echo "$(ts) $n funds address holds $count output"; continue; }
  ins=$(echo "$utxo" | jq -r 'keys[] | "--tx-in " + .' | tr '\n' ' ')
  # shellcheck disable=SC2086
  $CLI transaction build --testnet-magic $M --change-address "$addr" $ins --out-file /tmp/consolidate-$n.draft >/dev/null || { echo "$(ts) $n consolidation build failed"; continue; }
  $CLI transaction sign --tx-body-file /tmp/consolidate-$n.draft --signing-key-file "$A/keys/$n-funds.sk" --out-file /tmp/consolidate-$n.signed
  $CLI transaction submit --testnet-magic $M --tx-file /tmp/consolidate-$n.signed >/dev/null || { echo "$(ts) $n consolidation submit failed"; continue; }
  for i in $(seq 180); do
    [ "$($CLI query utxo --address "$addr" --testnet-magic $M --out-file /dev/stdout | jq 'length')" = 1 ] && break
    sleep 1
  done
  echo "$(ts) $n funds address merged from $count outputs into 1 in $i s"
done
