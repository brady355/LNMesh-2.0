#!/usr/bin/env bash
# Demo 2: offline channel open. B opens B-C; funding tx relayed and confirmed via A.
source "$(dirname "$0")/lib.sh"
echo "== Demo 2: offline open"
show b; show c
if has_chan b c; then echo "B-C channel already open, skipping"; else
  open_chan b c 1000000
  CP=$(q b "lncli-mesh pendingchannels | jq -r '.pending_open_channels[0].channel.channel_point'")
  echo ">> B pendingchannels channel point: $CP"
  run a "bcli getrawmempool"
  q a "bcli getrawmempool | jq -e 'index(\"${CP%:*}\")' >/dev/null" && echo ">> funding txid ${CP%:*} is in A's mempool" || echo "!! funding txid NOT in A's mempool"
  mine 6
  echo ">> funding tx confirmed at height $(txheight ${CP%:*})"
fi
wait_active b c && wait_active c b
run b "lncli-mesh listchannels | jq -c '.channels[] | {peer: .remote_pubkey[0:10], active, capacity, local_balance, channel_point}'"
run c "lncli-mesh listchannels | jq -c '.channels[] | {peer: .remote_pubkey[0:10], active, capacity, local_balance, channel_point}'"
if has_chan a c; then echo "A-C channel already open, skipping"; else open_chan a c 1000000 400000; mine 6; fi
wait_active a c && echo "A-C active"
for h in a b c; do show $h; done
done_msg
