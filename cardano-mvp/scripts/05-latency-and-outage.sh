#!/usr/bin/env bash
# Runs on the gateway. Measures the payment latency over the mesh, then pays
# while the cardano-node of the gateway is frozen with SIGSTOP. hydra-node
# refuses payments once it has seen no block for the unsynced period, so
# series C runs until the first rejection or N_C payments and prints the time
# since the freeze. Then the script unfreezes the node, closes the head, fans
# out and reports the resource use of every process.
#   TOWER=1 05-latency-and-outage.sh [N_A] [N_B] [N_C] [contestationSeconds]
set -uo pipefail
. "$HOME/testbed.env"
. "$HOME/lnmesh-ada/lib.sh"
NA=${1:-50}; NB=${2:-20}; NC=${3:-10}; CP=${4:-60}; TOWER=${TOWER:-1}

echo "[$(ts)] === reset nodes (contestation ${CP}s, tower ${TOWER}) ==="
reset_all
TOWER=$TOWER CP=$CP $S all; sleep 3
offline_check
echo "[$(ts)] === open ==="; $C pi2 init; deposit pi2; deposit pi3
echo "[$(ts)] === series A: $NA payments pi2 -> pi3 (1 ADA) ==="
for i in $(seq $NA); do $C pi2 pay 1 | grep -E '^(OK|ERR)' | sed "s/^/A $i /"; done
echo "[$(ts)] === series B: $NB payments pi3 -> pi2 ==="
for i in $(seq $NB); do $C pi3 pay 1 | grep -E '^(OK|ERR)' | sed "s/^/B $i /"; done
$C pi2 bal
echo "[$(ts)] === freeze cardano-node (SIGSTOP): chain unreachable for both leaves ==="
kill -STOP $(pgrep -f '[c]ardano-node run')
T0=$(date +%s); sleep 2
timeout 3 $A/bin/cardano-cli conway query tip --testnet-magic 42 >/dev/null 2>&1 && echo "node still answering?!" || echo "[$(ts)] node frozen (no answer within 3s)"
echo "[$(ts)] === series C: up to $NC payments pi2 -> pi3 with the chain frozen ==="
for i in $(seq $NC); do
  out=$($C pi2 pay 1 | grep -E '^(OK|ERR)')
  echo "C $i +$(( $(date +%s) - T0 ))s $out"
  echo "$out" | grep -q '^ERR' && break
  sleep ${C_GAP:-3}
done
$C pi2 info
echo "[$(ts)] === unfreeze cardano-node ==="
kill -CONT $(pgrep -f '[c]ardano-node run'); sleep 5
$C pi2 info
echo "[$(ts)] === close by pi3 ==="
$C pi3 close
onchain
echo "[$(ts)] === resource use (RSS KiB, %CPU, uptime s) ==="
for n in pi2 pi3; do
  on_leaf $n "ps -o rss=,pcpu=,etimes= -p \$(pgrep -f '[h]ydra-node-exe' | head -1) | sed 's/^/$n hydra-node /'; ps -o rss=,pcpu=,etimes= -p \$(pgrep -f '[p]ersistence/bin/etcd' | head -1) | sed 's/^/$n etcd (spawned by hydra-node) /'; ps -o rss=,pcpu=,etimes= -p \$(pgrep -f '[h]ydrapay.py node') | sed 's/^/$n hydrapay /'; ps -o rss= -p \$(pgrep -f '[s]ockfwd.py unix2tcp') | sed 's/^/$n sockfwd /'"
done
if [ "$TOWER" = 1 ]; then
  for n in pi2 pi3; do
    ps -o rss=,pcpu=,etimes= -p "$(pgrep -f "[h]ydra-node-exe.*--node-id ${n}m" | head -1)" | sed "s/^/gw mirror-$n hydra-node /"
    ps -o rss=,pcpu=,etimes= -p "$(pgrep -f "[m]irror-$n/bin/etcd" | head -1)" | sed "s/^/gw mirror-$n etcd /"
    ps -o rss=,pcpu=,etimes= -p "$(pgrep -f "[h]ydrapay.py node -api 127.0.0.1:400${n#pi}")" | sed "s/^/gw mirror-$n observer /"
  done
fi
ps -o rss=,pcpu=,etimes= -p $(pgrep -f '[c]ardano-node run') | sed 's/^/gw cardano-node /'
du -sh $A/hydra-image $A/venv $A/hydra-layer.tar.gz | sed 's/^/size /'; ls -la $A/cardano/bin/cardano-node $A/cardano/bin/cardano-cli | awk '{print "binary bytes", $5, $9}'
