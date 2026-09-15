#!/usr/bin/env bash
# Runs on the gateway. Starts or restarts the perunpay nodes on the leaves and
# the tower on the gateway.
#   TOWER=1 02-start-nodes.sh [pi2|pi3|tower|all]      (default all, TOWER=1)
# With TOWER=1 the leaves send every signed state to the tower at GW_IP:6500.
# With TOWER=0 the script stops the tower, so the leaves run with their local
# watcher only. That is the baseline without a tower.
set -uo pipefail
. "$HOME/testbed.env"
E=$HOME/lnmesh-eth
TOWER=${TOWER:-1}
ADJ=$(python3 -c "import json;print(json.load(open('$E/contracts.json'))['adjudicator'])")
AH=$(python3 -c "import json;print(json.load(open('$E/contracts.json'))['asset_holder'])")
KEY_PI2=59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
KEY_PI3=5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
KEY_TOWER=7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
TOWER_ARG=""
[ "$TOWER" = 1 ] && TOWER_ARG="-tower $GW_IP:6500"

start_leaf() { # name key peer
  local me=$1 key=$2 peer=$3 pip
  pip=$(leaf_ip "$3")
  timeout 40 ssh $SSH_OPTS "$SSH_USER@$(leaf_ip "$me")" "pkill -x perunpay; sleep 0.5; cd ~/lnmesh-eth && setsid -f bash -c 'exec ~/bin/perunpay node -rpc ws://$GW_IP:8545 -chainid 1337 -key $key -adj $ADJ -ah $AH -wire $me.wire -peer $peer.pub -peer-host $pip:6000 -listen 0.0.0.0:6000 -db ~/lnmesh-eth/db -ctl 127.0.0.1:7000 $TOWER_ARG ${PERUNPAY_VERBOSE:-} >> ~/lnmesh-eth/node.log 2>&1 < /dev/null'; sleep 3; tail -1 ~/lnmesh-eth/node.log"
}

start_tower() {
  pkill -f '[p]erunpay tower'; sleep 0.5
  if [ "$TOWER" = 1 ]; then
    setsid -f bash -c "exec $HOME/bin/perunpay tower -rpc ws://127.0.0.1:8545 -chainid 1337 -key $KEY_TOWER -adj $ADJ -listen 0.0.0.0:6500 >> $E/logs/tower.log 2>&1 < /dev/null"
    sleep 2; tail -1 "$E/logs/tower.log"
  else
    echo "tower stopped"
  fi
}

case "${1:-all}" in
  pi2) start_leaf pi2 $KEY_PI2 pi3 ;;
  pi3) start_leaf pi3 $KEY_PI3 pi2 ;;
  tower) start_tower ;;
  all) start_tower; start_leaf pi2 $KEY_PI2 pi3; start_leaf pi3 $KEY_PI3 pi2 ;;
  *) echo "usage: TOWER=0|1 $0 [pi2|pi3|tower|all]"; exit 2 ;;
esac
