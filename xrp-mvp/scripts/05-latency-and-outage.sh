#!/usr/bin/env bash
# Runs on the gateway. Measures the payment latency over the mesh, then pays
# while the xrpld of the gateway is frozen with SIGSTOP, then closes the
# channel cooperatively and reports the resource use of every process.
#   05-latency-and-outage.sh [N_A] [N_C]
set -uo pipefail
. "$HOME/testbed.env"
E=$HOME/lnmesh-xrp; C=$E/ctl.sh; S=$E/02-start-nodes.sh
NA=${1:-50}; NC=${2:-10}

echo "[$(ts)] === reset nodes (tower on) ==="
on_leaf pi2 "pkill -f '[x]rppay.py node'; rm -f ~/lnmesh-xrp/state.json*"
on_leaf pi3 "pkill -f '[x]rppay.py node'; rm -f ~/lnmesh-xrp/state.json*"
rm -f "$E/tower.json"
TOWER=1 $S all >/dev/null; sleep 2
offline_check
echo "[$(ts)] === open ==="; $C pi2 open 1 60
echo "[$(ts)] === series A: $NA payments pi2 -> pi3 (0.001 XRP) ==="
for i in $(seq $NA); do $C pi2 pay 0.001 | grep -E '^(OK|ERR)' | sed "s/^/A $i /"; done
$C pi2 bal
echo "[$(ts)] === freeze xrpld (SIGSTOP): chain RPC unreachable ==="
kill -STOP $(pgrep -f '[b]in/xrpld')   # xrpld renames its main thread, so the command line is the reliable match
sleep 2
curl -s -m 3 -X POST -H 'Content-Type: application/json' -d '{"method":"server_info","params":[{}]}' http://127.0.0.1:5005 >/dev/null && echo "rpc still answering?!" || echo "[$(ts)] rpc frozen (no answer within 3s)"
echo "[$(ts)] === series C: $NC payments pi2 -> pi3 with the chain frozen ==="
for i in $(seq $NC); do $C pi2 pay 0.001 | grep -E '^(OK|ERR)' | sed "s/^/C $i /"; done
$C pi3 bal
$C pi3 watch
echo "[$(ts)] === unfreeze xrpld ==="
kill -CONT $(pgrep -f '[b]in/xrpld'); sleep 7
$C pi2 onchain
echo "[$(ts)] === tower pushes seen by pi3 ==="
on_leaf pi3 "grep -c 'TOWER holds' ~/lnmesh-xrp/node.log | sed 's/^/pushes /'; grep 'TOWER holds' ~/lnmesh-xrp/node.log | tail -2"
echo "[$(ts)] === cooperative close by the payee ==="
$C pi3 close in
$C pi2 onchain; $C pi3 onchain
echo "[$(ts)] === resource use (RSS KiB, %CPU, uptime s) ==="
on_leaf pi2 "ps -o rss=,pcpu=,etimes=,args= -C python | grep '[x]rppay.py node' | sed 's/^/pi2 xrppay /' | cut -c1-60"
on_leaf pi3 "ps -o rss=,pcpu=,etimes=,args= -C python | grep '[x]rppay.py node' | sed 's/^/pi3 xrppay /' | cut -c1-60"
ps -o rss=,pcpu=,etimes= -p "$(pgrep -f '[x]rppay.py tower')" | sed 's/^/gw tower /'
ps -o rss=,pcpu=,etimes= -p "$(pgrep -f '[b]in/xrpld')" | sed 's/^/gw xrpld /'
ls -la "$HOME/bin/xrpld" | awk '{print "xrpld binary bytes", $5}'
du -sh "$E/venv" | awk '{print "venv size", $1}'
