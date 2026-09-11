#!/usr/bin/env bash
# Demo 1: offline funding. A opens A-B with push (B needs no on-chain funds),
# then A pays B and C on-chain. All of it reaches the chain only via A.
source "$(dirname "$0")/lib.sh"
echo "== Demo 1: offline funding"
for h in a b c; do show $h; done
if has_chan a b; then echo "A-B channel already open, skipping"; else
  open_chan a b 1000000 400000
  FUND=$(q b "lncli-mesh pendingchannels | jq -r '.pending_open_channels[0].channel.channel_point'")
  echo "A-B funding channel point: $FUND"
  run a "bcli getrawmempool"
  mine 6
fi
wait_active a b && echo "A-B active on A"; wait_active b a && echo "A-B active on B"
echo ">> B channel balance $(chanbal b) sat, B on-chain $(wallet b) sat  (balance with zero on-chain funds)"
for h in b c; do
  if [ "$(wallet $h)" -lt 2000000 ]; then
    addr=$(q $h "lncli-mesh newaddress p2tr | jq -r .address"); echo "[$(date +%T)] $h\$ lncli-mesh newaddress p2tr   -> $addr"
    run a "lncli-mesh sendcoins --addr $addr --amt 2000000 --sat_per_vbyte 1"
  else echo "$h already funded on-chain, skipping"; fi
done
run a "bcli getrawmempool"
mine 6
for h in a b c; do show $h; done
done_msg
