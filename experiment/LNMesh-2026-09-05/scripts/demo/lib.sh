#!/usr/bin/env bash
# Shared helpers for scripts/demo/*.sh. Sourced, not run.
# Every remote command is printed with a timestamp before it runs, and all
# output is teed to results/<date>/<demo>.log.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source hosts.env
DATE="${DATE:-$(date +%F)}"
RESULTS="results/$DATE"; mkdir -p "$RESULTS"
DEMO="$(basename "$0" .sh)"
LOG="$RESULTS/$DEMO.log"
exec > >(tee -a "$LOG") 2>&1
echo; echo "##### $DEMO start $(date +%Y-%m-%dT%H:%M:%S)"
RP='export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin;'

run() { local h=$1; shift; echo "[$(date +%T)] $h\$ $*"; ssh -o BatchMode=yes "lnmesh-$h" "$RP $*"; }
q()   { local h=$1; shift; ssh -o BatchMode=yes "lnmesh-$h" "$RP $*"; }
pk()  { case $1 in a) echo "$PK_A";; b) echo "$PK_B";; c) echo "$PK_C";; esac; }
mip() { case $1 in a) echo 10.10.0.1;; b) echo 10.10.0.2;; c) echo 10.10.0.3;; esac; }
height() { q a "bcli getblockcount"; }
mine() { run a "mine ${1:-1}"; sleep 4; }
connect() { q $1 "lncli-mesh connect $(pk $2)@$(mip $2):9735 >/dev/null 2>&1 || true"; }
chan_point() { q $1 "lncli-mesh listchannels | jq -r '.channels[] | select(.remote_pubkey==\"$(pk $2)\") | .channel_point' | head -1"; }
has_chan() { [ -n "$(chan_point $1 $2)" ]; }
wait_active() { for i in $(seq 1 30); do q $1 "lncli-mesh listchannels | jq -e '.channels[] | select(.remote_pubkey==\"$(pk $2)\" and .active)' >/dev/null 2>&1" && return 0; sleep 2; done; echo "!! channel $1-$2 not active after 60 s"; return 1; }
wait_synced() { for h in "$@"; do for i in $(seq 1 60); do q $h "lncli-mesh getinfo 2>/dev/null | jq -e .synced_to_chain >/dev/null 2>&1" && break; sleep 2; done; done; }
open_chan() { # open_chan <from> <to> <local_amt> [push_amt]; retries while wallet syncs
  local push=""; [ -n "${4:-}" ] && push="--push_amt $4"
  connect $1 $2; wait_synced $1
  for i in 1 2 3 4 5 6; do
    out=$(q $1 "lncli-mesh openchannel --node_key $(pk $2) --local_amt $3 $push --private --sat_per_vbyte 1 2>&1")
    echo "[$(date +%T)] $1\$ lncli-mesh openchannel --node_key $(pk $2) --local_amt $3 $push --private --sat_per_vbyte 1"; echo "$out"
    echo "$out" | grep -q funding_txid && return 0
    echo "   (retry $i in 10 s)"; sleep 10
  done; return 1; }
wallet()  { q $1 "lncli-mesh walletbalance | jq -r .confirmed_balance"; }
chanbal() { q $1 "lncli-mesh channelbalance | jq -r .local_balance.sat"; }
show() { echo "-- $1: on-chain confirmed=$(wallet $1) sat, channel local=$(chanbal $1) sat, height=$(height)"; }
pay() { # pay <payer> <payee> <amt> <memo>
  local inv; inv=$(q $2 "lncli-mesh addinvoice --amt $3 --memo '$4' | jq -r .payment_request")
  echo "[$(date +%T)] $2\$ lncli-mesh addinvoice --amt $3 --memo '$4'   -> ${inv:0:32}..."
  run $1 "lncli-mesh payinvoice --force $inv 2>&1 | grep -vE '^\s*$' | tail -8"; }
close_chan() { # close_chan <host> <peer> [--force]
  local cp; cp=$(chan_point $1 $2); [ -z "$cp" ] && { echo "!! no channel $1-$2"; return 1; }
  local extra="--sat_per_vbyte 1"; [ "${3:-}" = "--force" ] && extra="--force"
  run $1 "lncli-mesh closechannel --funding_txid ${cp%:*} --output_index ${cp#*:} $extra 2>&1 | head -5"; }
txheight() { q a "bcli getrawtransaction $1 1 | jq -r .blockhash" | xargs -I{} ssh -o BatchMode=yes lnmesh-a "$RP bcli getblockheader {} | jq -r .height"; }
require_regtest() { for h in a b c; do n=$(q $h "lncli-mesh getinfo | jq -r '.chains[0].network'"); [ "$n" = regtest ] || { echo "!! $h is on $n, not regtest. ABORT."; exit 1; }; done; [ "$(q a 'bcli getblockchaininfo | jq -r .chain')" = regtest ] || { echo "!! bitcoind not regtest. ABORT."; exit 1; }; echo "regtest confirmed on bitcoind and all three lnd"; }
done_msg() { echo "##### $DEMO end $(date +%Y-%m-%dT%H:%M:%S)"; }
