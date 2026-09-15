#!/usr/bin/env bash
# Runs on the gateway. The run opens a channel from pi2 to pi3 and pays through
# it. Then it tries two cheats, redeems a checkpoint, opens the reverse channel
# from pi3 to pi2, pays both ways and closes both channels cooperatively. XRPL
# channels are unidirectional, so two channels give the two payment directions
# of the other arms.
#   03-basic.sh [channelXRP] [settleSeconds]
set -uo pipefail
. "$HOME/testbed.env"
E=$HOME/lnmesh-xrp; C=$E/ctl.sh; S=$E/02-start-nodes.sh
CH=${1:-1}; SD=${2:-60}

echo "[$(ts)] === step 0: reset node state, restart nodes and tower ==="
on_leaf pi2 "pkill -f '[x]rppay.py node'; rm -f ~/lnmesh-xrp/state.json*"
on_leaf pi3 "pkill -f '[x]rppay.py node'; rm -f ~/lnmesh-xrp/state.json*"
rm -f "$E/tower.json"
TOWER=1 $S all >/dev/null; sleep 2
offline_check
$C pi2 info; $C pi2 peerping
$C pi2 onchain; $C pi3 onchain
echo "[$(ts)] === step 1: open channel pi2 -> pi3 (${CH} XRP, settle ${SD}s) ==="
$C pi2 open $CH $SD
$C pi2 chan out; $C pi3 chan in
echo "[$(ts)] === step 2: five payments of 0.01 XRP ==="
for i in 1 2 3 4 5; do $C pi2 pay 0.01; done
$C pi2 bal; $C pi3 bal
echo "[$(ts)] === step 3: cheating attempts ==="
echo "-- the payer signs a claim beyond the channel funding, so the payee must reject it offline"
$C pi2 pay 5 force
echo "-- the payee forges a claim of 0.5 XRP with its own key, so the ledger must reject it"
$C pi3 forge 0.5
$C pi3 bal
echo "[$(ts)] === step 4: checkpoint redeem by the payee (0.05 XRP), the channel stays open ==="
$C pi3 redeem
$C pi3 chan in
echo "[$(ts)] === step 5: reverse channel pi3 -> pi2, two payments each way ==="
$C pi3 open $CH $SD
$C pi3 pay 0.01; $C pi3 pay 0.01
$C pi2 pay 0.01; $C pi2 pay 0.01
$C pi2 bal; $C pi3 bal
echo "[$(ts)] === step 6: what the tower holds ==="
$C pi3 tower; $C pi2 tower
echo "[$(ts)] === step 7: cooperative close of both channels by the payees ==="
$C pi3 close in
$C pi2 close in
$C pi2 chan out; $C pi3 chan out
$C pi2 bal; $C pi3 bal
$C pi2 onchain; $C pi3 onchain
echo "[$(ts)] === logs ==="
echo "--- tower ---"; grep -E 'HOLD|WATCH|SUBMIT|VALIDATED' "$E/logs/tower.log" | tail -8
echo "--- pi3 ---"; on_leaf pi3 "grep -E 'CLAIM|WATCHER|IN channel|TOWER' ~/lnmesh-xrp/node.log | tail -14"
echo "--- pi2 ---"; on_leaf pi2 "grep -E 'OUT channel|CLOSE|TOWER' ~/lnmesh-xrp/node.log | tail -8"
