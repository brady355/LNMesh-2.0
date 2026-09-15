#!/usr/bin/env bash
# Runs on the gateway. Stale-state attack by pi2 against pi3. pi2 copies its
# channel database at version 0, pays pi3 five times, restores the copy and
# force-closes with the stale state.
#   04-cheat-test.sh <challengeSeconds> <online|offline:N> [tower]
# Victim modes:
#   online     pi3 stays up, so its own watcher refutes the stale state.
#   offline:N  The script stops pi3 before the attack and restarts it N
#              seconds after the stale registration lands on chain. Without a
#              tower pi3 wins only if it returns inside the challenge window.
#              With the tower argument the gateway tower holds the latest state
#              of pi3 and refutes for it.
set -uo pipefail
. "$HOME/testbed.env"
E=$HOME/lnmesh-eth; C=$E/ctl.sh; S=$E/02-start-nodes.sh; L=$E/logs
CH=${1:-60}; MODE=${2:-online}; TOWER=0; [ "${3:-}" = tower ] && TOWER=1
ADJ=$(python3 -c "import json;print(json.load(open('$E/contracts.json'))['adjudicator'])")
CAST="$HOME/.foundry/bin/cast call --rpc-url http://127.0.0.1:8545 $ADJ disputes(bytes32)(uint64,uint64,uint64,uint8,bytes32,bool)"
mkdir -p "$L"

echo "[$(ts)] === step 0: reset channel databases, restart nodes (challenge ${CH}s, victim ${MODE}, tower ${TOWER}) ==="
on_leaf pi2 "pkill -x perunpay; rm -rf ~/lnmesh-eth/db ~/lnmesh-eth/db.snap0"
on_leaf pi3 "pkill -x perunpay; rm -rf ~/lnmesh-eth/db"
TOWER=$TOWER $S all >/dev/null; sleep 2
offline_check
echo "[$(ts)] === step 1: open channel 1 ETH + 1 ETH ==="
$C pi2 onchain; $C pi3 onchain
out=$($C pi2 open 1 1 $CH); echo "$out"
CHID=$(echo "$out" | grep -oE 'channel=[0-9a-f]+' | cut -d= -f2)
echo "[$(ts)] === step 2: pi2 stops, copies its database at version 0, restarts ==="
on_leaf pi2 "pkill -x perunpay; sleep 1; rm -rf ~/lnmesh-eth/db.snap0; cp -a ~/lnmesh-eth/db ~/lnmesh-eth/db.snap0"
TOWER=$TOWER $S pi2 >/dev/null; sleep 2
$C pi2 bal
echo "[$(ts)] === step 3: pi2 pays pi3 five times (0.01 ETH) ==="
for i in 1 2 3 4 5; do $C pi2 pay 0.01; done
$C pi3 bal
if [ "$TOWER" = 1 ]; then echo "[$(ts)] tower holds:"; grep -E 'STATE|WATCHING' "$L/tower.log" | tail -1; fi
echo "[$(ts)] === step 4: pi2 stops, restores the stale copy, restarts ==="
on_leaf pi2 "pkill -x perunpay; sleep 1; rm -rf ~/lnmesh-eth/db; cp -a ~/lnmesh-eth/db.snap0 ~/lnmesh-eth/db"
TOWER=$TOWER $S pi2 >/dev/null; sleep 2
$C pi2 bal
if [[ $MODE == offline:* ]]; then
  echo "[$(ts)] === victim pi3 goes offline ==="
  on_leaf pi3 "pkill -x perunpay"; sleep 1
fi
echo "[$(ts)] === step 5: pi2 force-closes with the stale state (background) ==="
T0=$(date +%s); T0_HMS=$(date -u -d @$T0 +%H:%M:%S)
( $C pi2 forceclose > "$L/cheat-pi2-forceclose.out" 2>&1 ) &
FC=$!
# The registration lands one or more blocks after the command, and go-perun
# sometimes delivers the event a minute late, so the script reads the dispute
# from the Adjudicator contract itself. The registration time is the dispute
# timeout minus the challenge duration, in chain time.
T_REG=""
for i in $(seq 150); do
  timeout=$($CAST "0x$CHID" 2>/dev/null | head -1 | awk '{print $1}')   # cast appends a scientific hint
  if [ -n "$timeout" ] && [ "$timeout" != 0 ]; then
    T_REG=$((timeout - CH))
    echo "[$(ts)] stale state registered on chain at $(date -u -d @$T_REG +%H:%M:%S), timeout $(date -u -d @$timeout +%H:%M:%S), $(( T_REG - T0 )) s after the command"
    break
  fi
  sleep 2
done
[ -n "$T_REG" ] || { echo "[$(ts)] no registration seen within 300 s"; T_REG=$T0; }
if [ "$TOWER" = 1 ]; then
  # The subscription of the tower delivers the registration with the next block.
  for i in $(seq 30); do grep -q "RegisteredEvent channel=$CHID" "$L/tower.log" && break; sleep 1; done
  echo "[$(ts)] tower events after the registration:"; grep -E 'ADJUDICATOR' "$L/tower.log" | awk -v t="$T0_HMS" '$2 >= t' | tail -4 | sed 's/^/tower /'
fi
if [[ $MODE == offline:* ]]; then
  N=${MODE#offline:}
  echo "[$(ts)] victim stays offline until ${N}s after the registration"
  while [ $(( $(date +%s) - T_REG )) -lt "$N" ]; do sleep 1; done
  echo "[$(ts)] === victim pi3 comes back ==="
  TOWER=$TOWER $S pi3 >/dev/null; sleep 5
fi
on_leaf pi3 "awk -v t=$T0_HMS '\$2 >= t' ~/lnmesh-eth/node.log | grep -E 'ADJUDICATOR' | tail -3 | sed 's/^/pi3 /'"
echo "[$(ts)] === step 6: pi3 settles with its latest state ==="
$C pi3 forceclose
echo "[$(ts)] waiting for the force close of pi2 to return..."
wait $FC
echo "[$(ts)] pi2 force close result:"; grep -v rootSeed "$L/cheat-pi2-forceclose.out"
$C pi2 onchain; $C pi3 onchain
echo "[$(ts)] === logs ==="
if [ "$TOWER" = 1 ]; then echo "--- tower ---"; grep -E 'WATCHING|STATE|ADJUDICATOR|level=(warn|error)' "$L/tower.log" | awk -v t="$T0_HMS" '$2 >= t || /WATCHING/' | tail -12; fi
echo "--- pi3 ---"; on_leaf pi3 "grep -E 'ADJUDICATOR|ctl forceclose|node ready' ~/lnmesh-eth/node.log | tail -8"
echo "--- pi2 ---"; on_leaf pi2 "grep -E 'ADJUDICATOR|ctl forceclose|level=(warning|error)' ~/lnmesh-eth/node.log | tail -8"
