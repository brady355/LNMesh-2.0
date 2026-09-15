#!/usr/bin/env bash
# Runs on the gateway. Run 1 opens a channel, pays both ways and closes it
# cooperatively. Run 2 opens again, pays and closes unilaterally, so the close
# waits out the challenge duration. pi2 pays first.
#   03-basic.sh [challengeSeconds]
set -uo pipefail
. "$HOME/testbed.env"
E=$HOME/lnmesh-eth; C=$E/ctl.sh; S=$E/02-start-nodes.sh
CH=${1:-60}

echo "[$(ts)] === step 0: reset channel databases, restart nodes and tower ==="
on_leaf pi2 "pkill -x perunpay; rm -rf ~/lnmesh-eth/db ~/lnmesh-eth/db.snap0"
on_leaf pi3 "pkill -x perunpay; rm -rf ~/lnmesh-eth/db"
TOWER=1 $S all; sleep 2
offline_check
$C pi2 onchain; $C pi3 onchain
echo "[$(ts)] === run 1, step 1: open channel 1 ETH + 1 ETH, challenge ${CH}s ==="
$C pi2 open 1 1 $CH
echo "[$(ts)] === run 1, step 2: five payments pi2 -> pi3, two payments pi3 -> pi2 (0.01 ETH) ==="
for i in 1 2 3 4 5; do $C pi2 pay 0.01; done
for i in 1 2; do $C pi3 pay 0.01; done
$C pi2 bal; $C pi3 bal
echo "[$(ts)] === run 1, step 3: cooperative close by pi2, withdrawal by pi3 ==="
$C pi2 close
$C pi3 close
$C pi2 onchain; $C pi3 onchain
echo "[$(ts)] === run 2, step 1: open again and pay twice ==="
$C pi2 open 1 1 $CH
$C pi2 pay 0.01; $C pi2 pay 0.01
echo "[$(ts)] === run 2, step 2: unilateral close by pi2 (register, challenge ${CH}s, conclude, withdraw) ==="
$C pi2 forceclose
$C pi3 withdraw
$C pi2 onchain; $C pi3 onchain
echo "[$(ts)] === logs ==="
echo "--- tower ---"; grep -E 'WATCHING|ADJUDICATOR|STOPPED' "$E/logs/tower.log" | tail -12
echo "--- pi3 ---"; on_leaf pi3 "grep -E 'ADJUDICATOR|TOWER|ctl (open|close|forceclose|withdraw)' ~/lnmesh-eth/node.log | tail -12"
