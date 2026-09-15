#!/usr/bin/env bash
# Runs on the gateway. Sends a control command to the perunpay node of a leaf
# and prints the reply with a UTC timestamp. Usage: ctl.sh pi2 pay 0.01
set -uo pipefail
. "$HOME/testbed.env"
node=$1; shift
printf '%s %s> %s\n' "$(ts)" "$node" "$*"
# go-perun prints its test seed on every start, so the filter drops that line.
on_leaf "$node" "~/bin/perunpay ctl -addr 127.0.0.1:7000 $* 2>&1 | grep -v '^pkg/test: using rootSeed'"
