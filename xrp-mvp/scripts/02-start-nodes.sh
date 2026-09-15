#!/usr/bin/env bash
# Runs on the gateway. Starts or restarts the xrppay nodes on the leaves and
# the tower on the gateway.
#   TOWER=1 02-start-nodes.sh [pi2|pi3|tower|all]      (default all, TOWER=1)
# With TOWER=1 every payee pre-signs its newest claim and hands it to the tower
# at GW_IP:6600. With TOWER=0 the script stops the tower, so the leaves rely on
# their own watcher thread only. That is the baseline without a tower.
# The peer link uses port 6100 and the control port uses 7100. The Ethereum
# arm uses 6000 and 7000, so both arms can stay up at the same time.
set -uo pipefail
. "$HOME/testbed.env"
E=$HOME/lnmesh-xrp
RPC=${RPC:-http://$GW_IP:5005}
TOWER=${TOWER:-1}
TOWER_ARG=""
[ "$TOWER" = 1 ] && TOWER_ARG="-tower $GW_IP:6600"

start_leaf() { # name peer
  local me=$1 peer=$2 pip
  pip=$(leaf_ip "$2")
  # The kill runs in its own ssh session. Otherwise the pkill pattern would
  # match the command line of the shell that starts the node, so pkill would
  # kill that shell as well.
  on_leaf "$me" "pkill -f '[x]rppay.py node'; sleep 0.5"
  on_leaf "$me" "cd ~/lnmesh-xrp && setsid -f bash -c 'exec ~/lnmesh-xrp/venv/bin/python ~/lnmesh-xrp/xrppay.py node -rpc $RPC -key $me.json -peer $peer.pub -peer-host $pip:6100 -listen 0.0.0.0:6100 -ctl 127.0.0.1:7100 -state ~/lnmesh-xrp/state.json -poll ${XRPPAY_POLL:-2} $TOWER_ARG >> ~/lnmesh-xrp/node.log 2>&1 < /dev/null'; sleep 2; tail -1 ~/lnmesh-xrp/node.log"
}

start_tower() {
  pkill -f '[x]rppay.py tower'; sleep 0.5
  if [ "$TOWER" = 1 ]; then
    setsid -f bash -c "exec $E/venv/bin/python $E/xrppay.py tower -rpc http://127.0.0.1:5005 -listen 0.0.0.0:6600 -state $E/tower.json -poll ${XRPPAY_POLL:-2} >> $E/logs/tower.log 2>&1 < /dev/null"
    sleep 1; tail -1 "$E/logs/tower.log"
  else
    echo "tower stopped"
  fi
}

case "${1:-all}" in
  pi2) start_leaf pi2 pi3 ;;
  pi3) start_leaf pi3 pi2 ;;
  tower) start_tower ;;
  all) start_tower; start_leaf pi2 pi3; start_leaf pi3 pi2 ;;
  *) echo "usage: TOWER=0|1 $0 [pi2|pi3|tower|all]"; exit 2 ;;
esac
