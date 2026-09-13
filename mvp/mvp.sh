#!/usr/bin/env bash
# MVP driver: full Bitcoin nodes on a, b, c with a Bitcoin bus a-b-c.
#   ./mvp.sh copy      copy the Bitcoin Core tarball to all hosts
#   ./mvp.sh reset     move LND state to a backup dir on all hosts (chain kept)
#   ./mvp.sh bitcoind  install and configure bitcoind on a, b, c (bus peering)
#   ./mvp.sh lnd [neutrino]   configure LND on all (bitcoind backend, or neutrino on b and c)
#   ./mvp.sh fund      mine 101 to a, send 0.02 BTC on-chain to b and c
#   ./mvp.sh verify    heights, peers, sync state
#   ./mvp.sh bus-test  c opens a channel to b; funding tx must reach a via b
set -euo pipefail
cd "$(dirname "$0")"; source hosts.env
TAR="${TAR:-/tmp/bitcoin-29.1-aarch64-linux-gnu.tar.gz}"   # download from bitcoincore.org and verify SHA256SUMS first
rs() { local h=$1; shift; ssh -o BatchMode=yes "lnmesh-$h" "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; $*"; }
sudo_script() { local h=$1 s=$2; shift 2; ssh -o BatchMode=yes "lnmesh-$h" "sudo bash -s $*" < "$s"; }
mip() { case $1 in a) echo "$MESH_A";; b) echo "$MESH_B";; c) echo "$MESH_C";; esac; }
case "${1:-}" in
copy) for h in a b c; do echo "== $h"; scp -q "$TAR" "lnmesh-$h:/tmp/"; rs $h 'ls -la /tmp/bitcoin-29.1-aarch64-linux-gnu.tar.gz'; done ;;
reset) for h in a b c; do sudo_script $h reset-lnd.sh; done ;;
bitcoind)
  for h in a b c; do echo "== $h"; sudo_script $h install-bitcoind.sh 29.1; sudo_script $h configure-bitcoind.sh $h; done
  sleep 5; for h in a b c; do rs $h 'echo "$(hostname) peers=$(bcli getpeerinfo | jq -c "[.[].addr]")"'; done ;;
lnd)
  sudo_script a configure-lnd.sh a bitcoind
  for h in b c; do sudo_script $h configure-lnd.sh $h "${2:-bitcoind}"; done ;;
fund)
  rs a '[ -s /etc/lnmesh/mine.addr ] || lncli-mesh newaddress p2tr | jq -r .address | sudo tee /etc/lnmesh/mine.addr >/dev/null; mine 101 >/dev/null; sleep 3; while [ "$(lncli-mesh walletbalance | jq -r .confirmed_balance)" -lt 6000000 ]; do mine 50 >/dev/null; sleep 2; done; echo "a balance: $(lncli-mesh walletbalance | jq -r .confirmed_balance) sat, height $(bcli getblockcount)"'
  for h in b c; do addr=$(rs $h 'lncli-mesh newaddress p2tr | jq -r .address'); rs a "lncli-mesh sendcoins --addr $addr --amt 2000000 --sat_per_vbyte 1 | jq -c ."; done
  rs a 'sleep 2; mine 3'; sleep 8
  for h in a b c; do rs $h 'echo "$(hostname) height=$(lncli-mesh getinfo | jq -r .block_height) confirmed=$(lncli-mesh walletbalance | jq -r .confirmed_balance)"'; done ;;
verify)
  for h in a b c; do rs $h 'echo "$(hostname): bitcoind=$(systemctl is-active bitcoind) height=$(bcli getblockcount 2>/dev/null) peers=$(bcli getpeerinfo 2>/dev/null | jq -c "[.[].addr]") lnd=$(lncli-mesh getinfo 2>/dev/null | jq -c "{synced_to_chain,block_height,num_active_channels}") backend=$(sudo grep ^bitcoin.node /etc/lnd/lnd.conf | cut -d= -f2)"'; done ;;
bus-test)
  pkb=$(rs b 'lncli-mesh getinfo | jq -r .identity_pubkey')
  rs c "lncli-mesh connect $pkb@$MESH_B:9735 >/dev/null 2>&1 || true"
  echo "c peers (bitcoin): $(rs c 'bcli getpeerinfo | jq -c "[.[].addr]"')"
  echo "a peers (bitcoin): $(rs a 'bcli getpeerinfo | jq -c "[.[].addr]"')"
  out=$(rs c "lncli-mesh openchannel --node_key $pkb --local_amt 500000 --private --sat_per_vbyte 1"); echo "open: $out"
  txid=$(echo "$out" | sed -n 's/.*"funding_txid": *"\([0-9a-f]*\)".*/\1/p')
  for i in $(seq 1 30); do if rs a "bcli getrawmempool | jq -e 'index(\"$txid\")' >/dev/null"; then echo "funding tx $txid in a mempool after ${i}x1s"; break; fi; sleep 1; done
  rs a 'mine 6'; sleep 10
  for h in b c; do rs $h 'echo "$(hostname) $(lncli-mesh listchannels | jq -c "[.channels[] | {active, capacity}]")"'; done ;;
*) sed -n '2,10p' "$0"; exit 1 ;;
esac
