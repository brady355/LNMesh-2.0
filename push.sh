#!/usr/bin/env bash
# Runs on the laptop. Copies the testbed file, the shared latency script and
# the scripts and sources of each arm to the gateway. The gateway directories
# are ~/lnmesh-eth, ~/lnmesh-xrp and ~/lnmesh-ada, and the scripts run from
# there. GW_HOST names the gateway for ssh and defaults to pi1gateway.
#   push.sh [eth|xrp|ada|all]
set -euo pipefail
cd "$(dirname "$0")"
. ./testbed.env
GW=${GW_HOST:-pi1gateway}
S="ssh $SSH_OPTS $SSH_USER@$GW"
C="scp -q $SSH_OPTS"

# The files land in a staging directory first and move into place with mv, so
# a script that is running on the gateway keeps its old inode and is not torn.
push_arm() { # dir-in-repo dir-on-gateway
  $S "mkdir -p ~/$2/results ~/$2/logs ~/$2/.stage"
  $C "$1"/scripts/* common/latency-stats.py "$SSH_USER@$GW:~/$2/.stage/"
  $S "mv -f ~/$2/.stage/* ~/$2/ && rmdir ~/$2/.stage"
}

$C testbed.env "$SSH_USER@$GW:~/testbed.env"
case ${1:-all} in
  eth) push_arm ethereum-mvp lnmesh-eth; $S "mkdir -p ~/lnmesh-eth/perunpay"; $C ethereum-mvp/perunpay/* "$SSH_USER@$GW:~/lnmesh-eth/perunpay/" ;;
  xrp) push_arm xrp-mvp lnmesh-xrp; $C xrp-mvp/xrppay/xrppay.py "$SSH_USER@$GW:~/lnmesh-xrp/" ;;
  ada) push_arm cardano-mvp lnmesh-ada; $C cardano-mvp/hydrapay/hydrapay.py cardano-mvp/hydrapay/sockfwd.py "$SSH_USER@$GW:~/lnmesh-ada/" ;;
  all) for a in eth xrp ada; do bash "$(basename "$0")" "$a"; done; exit 0 ;;
  *) echo "usage: $0 [eth|xrp|ada|all]"; exit 2 ;;
esac
echo "pushed $1"
