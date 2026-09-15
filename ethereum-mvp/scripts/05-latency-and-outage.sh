#!/usr/bin/env bash
# Runs on the gateway. Measures the payment latency over the mesh, then pays
# while the chain process of the gateway (anvil) is frozen with SIGSTOP, then
# closes the channel cooperatively and reports the resource use of every
# process.
#   05-latency-and-outage.sh [N_A] [N_B] [N_C]
set -uo pipefail
. "$HOME/testbed.env"
E=$HOME/lnmesh-eth; C=$E/ctl.sh; S=$E/02-start-nodes.sh
N1=${1:-50}; N2=${2:-20}; N3=${3:-10}

echo "[$(ts)] === reset nodes (tower on) ==="
on_leaf pi2 "pkill -x perunpay; rm -rf ~/lnmesh-eth/db ~/lnmesh-eth/db.snap0"
on_leaf pi3 "pkill -x perunpay; rm -rf ~/lnmesh-eth/db"
TOWER=1 $S all >/dev/null; sleep 2
offline_check
echo "[$(ts)] === open ==="; $C pi2 open 1 1 60
echo "[$(ts)] === series A: $N1 payments pi2 -> pi3 (0.001 ETH) ==="
for i in $(seq $N1); do $C pi2 pay 0.001 | grep -E '^(OK|ERR)' | sed "s/^/A $i /"; done
echo "[$(ts)] === series B: $N2 payments pi3 -> pi2 ==="
for i in $(seq $N2); do $C pi3 pay 0.001 | grep -E '^(OK|ERR)' | sed "s/^/B $i /"; done
$C pi2 bal
echo "[$(ts)] === freeze anvil (SIGSTOP): chain RPC unreachable ==="
kill -STOP $(pgrep -x anvil)
sleep 2
curl -s -m 3 -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' http://127.0.0.1:8545 >/dev/null && echo "rpc still answering?!" || echo "[$(ts)] rpc frozen (no answer within 3s)"
echo "[$(ts)] === series C: $N3 payments pi2 -> pi3 with the chain frozen ==="
for i in $(seq $N3); do $C pi2 pay 0.001 | grep -E '^(OK|ERR)' | sed "s/^/C $i /"; done
$C pi3 bal
echo "[$(ts)] === unfreeze anvil ==="
kill -CONT $(pgrep -x anvil); sleep 13
$C pi2 onchain
echo "[$(ts)] === tower acknowledgements seen by pi2 ==="
on_leaf pi2 "grep -c 'TOWER ack' ~/lnmesh-eth/node.log | sed 's/^/acks /'; grep 'TOWER ack' ~/lnmesh-eth/node.log | tail -2"
echo "[$(ts)] === cooperative close ==="
$C pi2 close; $C pi3 close
$C pi2 onchain; $C pi3 onchain
echo "[$(ts)] === resource use (RSS KiB, %CPU, uptime s) ==="
on_leaf pi2 "ps -o rss=,pcpu=,etimes= -C perunpay | sed 's/^/pi2 perunpay /'"
on_leaf pi3 "ps -o rss=,pcpu=,etimes= -C perunpay | sed 's/^/pi3 perunpay /'"
ps -o rss=,pcpu=,etimes= -p "$(pgrep -f '[p]erunpay tower')" | sed 's/^/gw tower /'
ps -o rss=,pcpu=,etimes= -C anvil | sed 's/^/gw anvil /'
ls -la ~/bin/perunpay | awk '{print "binary bytes", $5}'
