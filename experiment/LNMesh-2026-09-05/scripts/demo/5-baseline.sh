#!/usr/bin/env bash
# Demo 5: baseline replication (LNMesh 2023). Pay with no chain access at all.
source "$(dirname "$0")/lib.sh"
echo "== Demo 5: pay with bitcoind stopped"
has_chan b c || { open_chan b c 1000000; mine 6; wait_active b c; }
run a "sudo systemctl stop bitcoind"; sleep 3
run a "systemctl is-active bitcoind || true"
pay b c 5000 "B to C with bitcoind stopped"
run b "lncli-mesh listpayments | jq -c '.payments[-1] | {value_sat, status}'"
run a "sudo systemctl start bitcoind"; sleep 10
wait_synced a b c
for h in a b c; do run $h "lncli-mesh getinfo | jq -c '{alias, synced_to_chain, block_height}'"; done
done_msg
