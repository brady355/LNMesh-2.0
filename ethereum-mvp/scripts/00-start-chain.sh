#!/usr/bin/env bash
# Runs on the gateway. Starts a fresh anvil dev chain with the block interval
# of Ethereum mainnet, 12 s. anvil keeps the chain in memory, so a restart
# wipes the contracts and the balances. Run 01-deploy-and-distribute.sh again
# afterwards and wipe the channel databases on the leaves.
#   00-start-chain.sh [blockSeconds]
set -euo pipefail
. "$HOME/testbed.env"
E=$HOME/lnmesh-eth
BLOCK=${1:-12}
mkdir -p "$E/logs"
pkill -x anvil || true
sleep 1
rm -f "$E/contracts.json"
setsid -f bash -c "exec $HOME/.foundry/bin/anvil --host 0.0.0.0 --port 8545 --chain-id 1337 --block-time $BLOCK --silent >> $E/logs/anvil.log 2>&1 < /dev/null"
for i in $(seq 30); do
  curl -s -m 2 -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' http://127.0.0.1:8545 | grep -q 0x539 && break
  sleep 1
done
echo "anvil up: chain id 1337, one block every ${BLOCK} s, rpc ws://$GW_IP:8545 for the leaves"
