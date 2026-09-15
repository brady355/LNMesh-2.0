#!/usr/bin/env bash
# Runs on the gateway. The run opens a head, deposits on both sides, pays both
# ways and closes. The close waits out the contestation period and then fans
# out. pi2 pays pi3 first. The mirrors on the gateway take part unless TOWER=0.
#   TOWER=1 03-basic.sh [contestationSeconds]
set -uo pipefail
. "$HOME/testbed.env"
. "$HOME/lnmesh-ada/lib.sh"
CP=${1:-60}; TOWER=${TOWER:-1}

echo "[$(ts)] === step 0: reset head state, restart nodes (contestation ${CP}s, tower ${TOWER}) ==="
reset_all
TOWER=$TOWER CP=$CP $S all; sleep 3
offline_check
$C pi2 info; $C pi3 info
onchain
echo "[$(ts)] === step 1: init the head and deposit on each side ==="
$C pi2 init
deposit pi2
deposit pi3
$C pi2 bal; $C pi3 bal
echo "[$(ts)] === step 2: five payments of 1 ADA pi2 -> pi3, two payments pi3 -> pi2 ==="
for i in 1 2 3 4 5; do $C pi2 pay 1; done
for i in 1 2; do $C pi3 pay 1; done
$C pi2 bal; $C pi3 bal; $C pi2 snapshot
[ "$TOWER" = 1 ] && { $C pi3m snapshot; $C pi3m bal; }
echo "[$(ts)] === step 3: close by pi2 (waits out the contestation period, then fans out) ==="
$C pi2 close
$C pi3 head
onchain
echo "[$(ts)] === logs ==="
echo "--- pi2 ---"; on_leaf pi2 "grep -E 'HEAD|DEPOSIT|SNAPSHOT [0-9]+ confirmed, [1-9]|ctl (init|deposit|pay|close)' ~/lnmesh-ada/node.log | tail -25"
echo "--- pi3 ---"; on_leaf pi3 "grep -E 'HEAD|DEPOSIT|ctl' ~/lnmesh-ada/node.log | tail -15"
[ "$TOWER" = 1 ] && { echo "--- mirror of pi3 ---"; grep -E 'HEAD|SNAPSHOT [0-9]+ confirmed, [1-9]|GREETINGS' "$L/mirror-pi3-observer.log" | tail -15; }
