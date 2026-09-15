#!/usr/bin/env bash
# Runs on the gateway. Stale-snapshot attack by pi2 against pi3, the Hydra
# analog of the stale-state attack. pi2 copies its hydra-node persistence,
# which holds hydra.db and the etcd data, right after the deposits. Then it
# pays pi3 five times, restores the copy, closes the head with the old snapshot
# and fans out as soon as its node allows.
#   04-cheat-test.sh <contestationSeconds> <online|offline:N> [tower]
# Victim modes:
#   online     The hydra-node of pi3 stays up the whole time. The leaves have
#              no sudo, so the script cannot cut the peer link. This mode shows
#              what the Hydra network layer does with a rolled-back peer.
#   offline:N  The script stops the hydra-node of pi3 before the attack and
#              restarts it N seconds after the close of pi2 lands. Without a
#              tower pi3 wins only if it returns inside the contestation
#              window. With the tower argument the mirror of pi3 on the gateway
#              contests for it. The script stops the mirror of the attacker
#              before the attack, because an attacker would not keep a mirror
#              that works against it. With the victim offline and that mirror
#              stopped, the etcd cluster of four nodes has no quorum, so the
#              network layer cannot resynchronise the rolled-back attacker
#              before it closes.
set -uo pipefail
. "$HOME/testbed.env"
. "$HOME/lnmesh-ada/lib.sh"
CP=${1:-60}; MODE=${2:-offline:0}; N=${MODE#offline:}; TOWER=0; [ "${3:-}" = tower ] && TOWER=1
mkdir -p "$L"

echo "[$(ts)] === step 0: reset head state, restart nodes (contestation ${CP}s, victim ${MODE}, tower ${TOWER}) ==="
reset_all
TOWER=$TOWER CP=$CP $S all >/dev/null; sleep 3
offline_check
onchain
echo "[$(ts)] === step 1: init, deposits on both sides ==="
$C pi2 init; deposit pi2; deposit pi3
$C pi2 bal
echo "[$(ts)] === step 2: pi2 copies its hydra-node persistence, restarts ==="
on_leaf pi2 "pkill -f '[h]ydra-node-exe'; sleep 2; rm -rf ~/lnmesh-ada/persistence.snap0; cp -a ~/lnmesh-ada/persistence ~/lnmesh-ada/persistence.snap0; ls ~/lnmesh-ada/persistence | tr '\n' ' '; echo"
TOWER=$TOWER CP=$CP $S pi2 >/dev/null; sleep 3
$C pi2 snapshot
echo "[$(ts)] === step 3: pi2 pays pi3 five times (1 ADA) ==="
for i in 1 2 3 4 5; do $C pi2 pay 1; done
$C pi3 bal; $C pi3 snapshot
if [ "$TOWER" = 1 ]; then
  $C pi3m snapshot
  echo "[$(ts)] === step 3b: the mirror of the attacker stops ==="
  pkill -f '[h]ydra-node-exe.*--node-id pi2m'; pkill -f '[h]ydrapay.py node -api 127.0.0.1:4002'
fi
if [[ $MODE == offline:* ]]; then
  echo "[$(ts)] === step 4: victim pi3 goes offline, pi2 restores the stale copy and restarts ==="
  on_leaf pi3 "pkill -f '[h]ydra-node-exe'"; sleep 1
else
  echo "[$(ts)] === step 4: victim pi3 stays online, pi2 restores the stale copy and restarts ==="
fi
on_leaf pi2 "pkill -f '[h]ydra-node-exe'; sleep 2; rm -rf ~/lnmesh-ada/persistence; cp -a ~/lnmesh-ada/persistence.snap0 ~/lnmesh-ada/persistence"
TOWER=$TOWER CP=$CP $S pi2 >/dev/null; sleep 5
$C pi2 snapshot; $C pi2 bal
echo "[$(ts)] === step 5: pi2 closes with what it has, then fans out as soon as its node allows (background) ==="
$C pi2 closeonly | tee "$L/cheat-pi2-close.out"
T_CLOSE=$(date +%s); T_CLOSE_HMS=$(date -u +%H:%M:%S)
( $C pi2 fanout > "$L/cheat-pi2-fanout.out" 2>&1 ) &
BG=$!
if [ "$TOWER" = 1 ]; then
  echo "[$(ts)] waiting for the mirror of pi3 to contest (up to 2 x CP)..."
  for i in $(seq $((2 * CP + 30))); do
    awk -v t="$T_CLOSE_HMS" '$1 >= t' "$L/mirror-pi3-observer.log" | grep -q 'HEAD contested' && break
    sleep 1
  done
  awk -v t="$T_CLOSE_HMS" '$1 >= t' "$L/mirror-pi3-observer.log" | grep -E 'HEAD (closed|contested)|POST TX' | sed 's/^/pi3m /'
fi
if [[ $MODE == offline:* ]]; then
  echo "[$(ts)] victim stays offline until ${N}s after the close"
  while [ $(( $(date +%s) - T_CLOSE )) -lt "$N" ]; do sleep 1; done
  echo "[$(ts)] === step 6: victim pi3 comes back ==="
  TOWER=$TOWER CP=$CP $S pi3 >/dev/null; sleep 5
fi
$C pi3 head
echo "[$(ts)] contest as seen by the hydra-node of pi3 and by the client of pi2:"
on_leaf pi3 "python3 ~/lnmesh-ada/contest-log.py ~/lnmesh-ada/hydra-node.log $T_CLOSE_HMS | sed 's/^/pi3 hydra-node /'"
on_leaf pi2 "awk -v t=$T_CLOSE_HMS '\$1 >= t' ~/lnmesh-ada/node.log | grep -E 'HEAD contested' | tail -1 | sed 's/^/pi2 /'"
echo "[$(ts)] === step 7: fanout, waiting for every fanout ==="
# After a contest only a node that holds the newer snapshot can fan out, so
# the fanout of the attacker in the background fails, and the mirror or the
# returning victim posts it.
[ "$TOWER" = 1 ] && $C pi3m fanout | tee "$L/cheat-pi3m-fanout.out"
$C pi3 fanout | tee "$L/cheat-pi3-fanout.out"
wait $BG; echo "pi2 fanout result:"; cat "$L/cheat-pi2-fanout.out"
onchain
echo "[$(ts)] === logs ==="
echo "--- pi3 ---"; on_leaf pi3 "grep -E 'HEAD|node ready|ctl fanout|POST TX' ~/lnmesh-ada/node.log | tail -8 | cut -c1-300"
echo "--- pi2 ---"; on_leaf pi2 "grep -E 'HEAD|node ready|ctl (closeonly|fanout)|COMMAND FAILED|POST TX' ~/lnmesh-ada/node.log | tail -10"
[ "$TOWER" = 1 ] && { echo "--- mirror of pi3 ---"; grep -E 'HEAD|POST TX|node ready' "$L/mirror-pi3-observer.log" | tail -10; }
