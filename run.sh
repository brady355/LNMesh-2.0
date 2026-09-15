#!/usr/bin/env bash
# Runs on the laptop. Runs one experiment script on the gateway and records the
# transcript under the results directory of the arm. GW_HOST names the gateway
# for ssh and defaults to pi1gateway.
#   run.sh eth|xrp|ada <name> <script> [args...]
# For example
#   run.sh eth run-04-tower-offline120 04-cheat-test.sh 60 offline:120 tower
# writes ethereum-mvp/results/run-04-tower-offline120.txt.
set -uo pipefail
cd "$(dirname "$0")"
. ./testbed.env
GW=${GW_HOST:-pi1gateway}
case ${1:-} in
  eth) arm=ethereum-mvp; d=lnmesh-eth ;;
  xrp) arm=xrp-mvp; d=lnmesh-xrp ;;
  ada) arm=cardano-mvp; d=lnmesh-ada ;;
  *) echo "usage: $0 eth|xrp|ada <name> <script> [args...]"; exit 2 ;;
esac
[ $# -ge 3 ] || { echo "usage: $0 eth|xrp|ada <name> <script> [args...]"; exit 2; }
name=$2; script=$3; shift 3
mkdir -p "$arm/results"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$SSH_USER@$GW" "bash ~/$d/$script $*" 2>&1 | tee "$arm/results/$name.txt"
