#!/usr/bin/env bash
# Runs on the gateway. The payer requests the closure of the channel while
# claims are still unredeemed. This is the XRPL analog of the stale-state
# attack, because the payer takes back every unredeemed drop once the settle
# delay has passed. pi2 pays pi3 five times and then requests the close, so
# pi3 must redeem its best claim within the settle delay.
#   04-close-test.sh <settleSeconds> <online|offline:N> [tower]
# Victim modes:
#   online     pi3 stays up, so its own watcher redeems as soon as it sees the
#              scheduled expiration.
#   offline:N  The script stops pi3 before the close request and restarts it
#              N seconds after the request. Without a tower pi3 is paid only
#              if it returns inside the settle delay. With the tower argument
#              the gateway tower holds the pre-signed claim of pi3 and submits
#              it for pi3.
set -uo pipefail
. "$HOME/testbed.env"
E=$HOME/lnmesh-xrp; C=$E/ctl.sh; S=$E/02-start-nodes.sh; L=$E/logs
SD=${1:-60}; MODE=${2:-online}; TOWER=0; [ "${3:-}" = tower ] && TOWER=1
mkdir -p "$L"

echo "[$(ts)] === step 0: reset node state, restart nodes (settle ${SD}s, victim ${MODE}, tower ${TOWER}) ==="
on_leaf pi2 "pkill -f '[x]rppay.py node'; rm -f ~/lnmesh-xrp/state.json*"
on_leaf pi3 "pkill -f '[x]rppay.py node'; rm -f ~/lnmesh-xrp/state.json*"
rm -f "$E/tower.json"
TOWER=$TOWER $S all >/dev/null; sleep 2
offline_check
echo "[$(ts)] === step 1: open channel 1 XRP, settle ${SD}s ==="
$C pi2 onchain; $C pi3 onchain
$C pi2 open 1 $SD
echo "[$(ts)] === step 2: pi2 pays pi3 five times (0.01 XRP) ==="
for i in 1 2 3 4 5; do $C pi2 pay 0.01; done
sleep 6   # the payee hands its newest pre-signed claim to the tower in the background
$C pi3 bal
[ "$TOWER" = 1 ] && $C pi3 tower
if [[ $MODE == offline:* ]]; then
  echo "[$(ts)] === victim pi3 goes offline ==="
  on_leaf pi3 "pkill -f '[x]rppay.py node'"; sleep 1
fi
echo "[$(ts)] === step 3: pi2 requests the close (background, it waits out the settle delay) ==="
T0=$(date +%s)
( $C pi2 close out > "$L/close-pi2.out" 2>&1 ) &
BG=$!
sleep 12
echo "[$(ts)] channel after the close request:"; $C pi2 chan out; $C pi2 ledger
if [ "$TOWER" = 1 ]; then echo "[$(ts)] tower so far:"; grep -E 'WATCH|SUBMIT|VALIDATED' "$L/tower.log" | tail -4; fi
if [[ $MODE == offline:* ]]; then
  N=${MODE#offline:}
  echo "[$(ts)] victim stays offline until ${N}s after the close request"
  while [ $(( $(date +%s) - T0 )) -lt "$N" ]; do sleep 1; done
  echo "[$(ts)] === victim pi3 comes back ==="
  TOWER=$TOWER $S pi3 >/dev/null; sleep 6
  $C pi3 watch
fi
echo "[$(ts)] waiting for the close of pi2 to return..."
wait $BG
echo "[$(ts)] pi2 close result:"; cat "$L/close-pi2.out"
echo "[$(ts)] === step 4: pi3 view ==="
$C pi3 bal; $C pi3 chan in
$C pi3 redeem
$C pi2 onchain; $C pi3 onchain
echo "[$(ts)] === logs ==="
if [ "$TOWER" = 1 ]; then echo "--- tower ---"; grep -E 'HOLD|WATCH|SUBMIT|VALIDATED' "$L/tower.log" | tail -8; fi
echo "--- pi3 ---"; on_leaf pi3 "grep -E 'CLAIM|WATCHER|TOWER|node ready|ctl (redeem|close)' ~/lnmesh-xrp/node.log | tail -14"
echo "--- pi2 ---"; on_leaf pi2 "grep -E 'CLOSE|OUT channel' ~/lnmesh-xrp/node.log | tail -8"
