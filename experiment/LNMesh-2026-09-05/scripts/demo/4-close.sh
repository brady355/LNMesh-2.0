#!/usr/bin/env bash
# Demo 4: offline close. B cooperatively closes A-B, force-closes B-C, sweeps
# after the 1008-block delay. Then both channels are reopened.
source "$(dirname "$0")/lib.sh"
echo "== Demo 4: offline close"
echo "== precondition: A-B and B-C must exist"
has_chan a b || open_chan a b 1000000 400000
has_chan b c || open_chan b c 1000000
mine 6; wait_active a b; wait_active b c
show b
if has_chan b a; then
  B0=$(wallet b)
  close_chan b a
  run a "bcli getrawmempool"
  mine 1
  run b "lncli-mesh closedchannels | jq -c '.channels[] | {peer: .remote_pubkey[0:10], close_type, closing_tx_hash, settled_balance, close_height}'"
  echo ">> B on-chain before coop close: $B0 sat, after: $(wallet b) sat"
else echo "no A-B channel to close"; fi
show b
if has_chan b c; then
  B0=$(wallet b)
  close_chan b c --force
  run a "bcli getrawmempool"
  mine 1
  run b "lncli-mesh pendingchannels | jq -c '.pending_force_closing_channels[] | {closing_txid, blocks_til_maturity, limbo_balance, maturity_height}'"
  echo ">> mining 1008 blocks for the CSV delay"
  mine 1008
  echo ">> waiting for all wallets to rescan"; wait_synced a b c
  for i in 1 2 3 4 5 6; do sleep 5; q a 'bcli getrawmempool | jq -e "length>0" >/dev/null' && break; done
  run a "bcli getrawmempool"
  mine 1
  sleep 5
  run b "lncli-mesh pendingchannels | jq -c '{force_closing: .pending_force_closing_channels}'"
  run b "lncli-mesh closedchannels | jq -c '.channels[] | select(.close_type==\"LOCAL_FORCE_CLOSE\") | {peer: .remote_pubkey[0:10], close_type, closing_tx_hash, settled_balance, close_height}'"
  echo ">> B on-chain before force close: $B0 sat, after sweep: $(wallet b) sat"
else echo "no B-C channel to close"; fi
show b
echo "== reopen B-C (from B) and A-B (from A, with push)"
wait_synced a b c
has_chan b c || open_chan b c 1000000
has_chan a b || open_chan a b 1000000 400000
mine 6
wait_active b c && wait_active a b && echo "B-C and A-B active again"
for h in a b c; do show $h; done
done_msg
