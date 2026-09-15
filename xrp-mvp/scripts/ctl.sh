#!/usr/bin/env bash
# Runs on the gateway. Sends a control command to the xrppay node of a leaf and
# prints the reply with a UTC timestamp. Usage: ctl.sh pi2 pay 0.01
set -uo pipefail
. "$HOME/testbed.env"
node=$1; shift
printf '%s %s> %s\n' "$(ts)" "$node" "$*"
on_leaf "$node" "~/lnmesh-xrp/venv/bin/python ~/lnmesh-xrp/xrppay.py ctl -addr 127.0.0.1:7100 $*"
