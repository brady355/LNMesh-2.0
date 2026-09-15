#!/usr/bin/env bash
# Runs on the gateway. Sends a control command to the hydrapay of a leaf, or to
# the observer of a mirror on the gateway, and prints the reply with a UTC
# timestamp. Usage: ctl.sh pi2 pay 1      ctl.sh pi3m head
set -uo pipefail
. "$HOME/testbed.env"
A=$HOME/lnmesh-ada
node=$1; shift
printf '%s %s> %s\n' "$(ts)" "$node" "$*"
case $node in
  pi2|pi3) on_leaf "$node" "~/lnmesh-ada/venv/bin/python ~/lnmesh-ada/hydrapay.py ctl -addr 127.0.0.1:7200 $*" ;;
  pi2m) "$A/venv/bin/python" "$A/hydrapay.py" ctl -addr 127.0.0.1:7202 "$@" ;;
  pi3m) "$A/venv/bin/python" "$A/hydrapay.py" ctl -addr 127.0.0.1:7203 "$@" ;;
  *) echo "node must be pi2, pi3, pi2m or pi3m"; exit 2 ;;
esac
