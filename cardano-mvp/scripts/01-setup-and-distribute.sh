#!/usr/bin/env bash
# Runs on the gateway. Creates the leaf keys, funds them from the devnet
# faucet, publishes the Hydra scripts, builds the Python environment and copies
# everything to the two leaves over the mesh. Nothing is compiled anywhere. The
# cardano binaries are static release builds, and hydra-node comes out of the
# arm64 Docker image (see hydra-node.sh and extract-image.py). The mirror nodes
# on the gateway use the same key files under keys/.
#   FUNDS_ADA=100 FUEL_ADA=100 01-setup-and-distribute.sh     SKIP_FUND=1 skips the funding
set -euo pipefail
. "$HOME/testbed.env"
A=$HOME/lnmesh-ada; B=$A/bin; M=42
FUNDS_ADA=${FUNDS_ADA:-100}; FUEL_ADA=${FUEL_ADA:-100}
export CARDANO_NODE_SOCKET_PATH=$A/devnet/node.socket
CLI="$B/cardano-cli conway"
cd "$A"; mkdir -p keys bin
install -m 755 hydra-node.sh bin/hydra-node

echo "== hydra-node image =="
if [ ! -f hydra-image/.ok ]; then
  if [ ! -f hydra-layer.tar.gz ]; then
    T=$(curl -s "https://ghcr.io/token?scope=repository:cardano-scaling/hydra-node:pull" | jq -r .token)
    D=$(curl -s -H "Authorization: Bearer $T" -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
      https://ghcr.io/v2/cardano-scaling/hydra-node/manifests/2.4.1 | jq -r '.manifests[] | select(.platform.architecture=="arm64") | .digest')
    L=$(curl -s -H "Authorization: Bearer $T" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      https://ghcr.io/v2/cardano-scaling/hydra-node/manifests/$D | jq -r '.layers[0].digest')
    curl -sL -H "Authorization: Bearer $T" -o hydra-layer.tar.gz https://ghcr.io/v2/cardano-scaling/hydra-node/blobs/$L
  fi
  python3 extract-image.py hydra-layer.tar.gz hydra-image
fi
bin/hydra-node --version

echo "== keys =="
for n in pi2 pi3; do
  [ -f keys/$n-node.sk ] || $CLI address key-gen --verification-key-file keys/$n-node.vk --signing-key-file keys/$n-node.sk
  [ -f keys/$n-funds.sk ] || $CLI address key-gen --verification-key-file keys/$n-funds.vk --signing-key-file keys/$n-funds.sk
  [ -f keys/$n-hydra.sk ] || bin/hydra-node gen-hydra-key --output-file keys/$n-hydra >/dev/null
  $CLI address build --payment-verification-key-file keys/$n-node.vk --testnet-magic $M > keys/$n-node.addr
  $CLI address build --payment-verification-key-file keys/$n-funds.vk --testnet-magic $M > keys/$n-funds.addr
  echo "$n node (fuel) $(cat keys/$n-node.addr)"; echo "$n funds       $(cat keys/$n-funds.addr)"
done
rm -f keys/*-funds-utxo.json

FAUCET_ADDR=$($CLI address build --payment-verification-key-file devnet/credentials/faucet.vk --testnet-magic $M)
seed() { # address lovelace
  local txin txid
  txin=$($CLI query utxo --address "$FAUCET_ADDR" --testnet-magic $M --out-file /dev/stdout | jq -r 'keys[0]')
  $CLI transaction build --testnet-magic $M --change-address "$FAUCET_ADDR" --tx-in "$txin" --tx-out "$1+$2" --out-file /tmp/seed.draft >/dev/null
  $CLI transaction sign --tx-body-file /tmp/seed.draft --signing-key-file devnet/credentials/faucet.sk --out-file /tmp/seed.signed
  txid=$($CLI transaction txid --tx-file /tmp/seed.signed | grep -oE '[0-9a-f]{64}' | head -1)
  $CLI transaction submit --testnet-magic $M --tx-file /tmp/seed.signed >/dev/null
  for i in $(seq 120); do
    [ "$($CLI query utxo --tx-in "$txid#0" --testnet-magic $M --out-file /dev/stdout | jq 'length')" != "0" ] && break
    sleep 1
  done
  echo "seeded $1 with $(($2 / 1000000)) ADA ($txid)"
}
if [ "${SKIP_FUND:-0}" != 1 ]; then
  echo "== funding from the faucet =="
  for n in pi2 pi3; do
    seed "$(cat keys/$n-node.addr)" $((FUEL_ADA * 1000000))
    seed "$(cat keys/$n-funds.addr)" $((FUNDS_ADA * 1000000))
  done
fi

echo "== head ledger parameters (fees zeroed, maxTxSize 10250, min-UTxO kept) =="
$CLI query protocol-parameters --testnet-magic $M --out-file /dev/stdout \
  | jq '.txFeeFixed = 0 | .txFeePerByte = 0 | .executionUnitPrices.priceMemory = 0 | .executionUnitPrices.priceSteps = 0 | .minFeeRefScriptCostPerByte = 0 | .maxTxSize = 10250' \
  > protocol-parameters.json
echo "utxoCostPerByte $(jq .utxoCostPerByte protocol-parameters.json)"

echo "== publishing the Hydra scripts on the devnet =="
if [ ! -s hydra-scripts.txid ]; then
  bin/hydra-node publish-scripts --testnet-magic $M --node-socket devnet/node.socket --cardano-signing-key devnet/credentials/faucet.sk | tail -1 > hydra-scripts.txid
fi
echo "HYDRA_SCRIPTS_TX_ID=$(cat hydra-scripts.txid)"

echo "== python venv =="
if [ ! -x venv/bin/python ] || ! venv/bin/python -c 'import pycardano, websocket' 2>/dev/null; then
  python3 -m venv venv && venv/bin/pip install -q pycardano websocket-client
fi
venv/bin/python -c 'import pycardano, websocket; print("pycardano ok")'

echo "== distributing =="
for pair in "pi2 pi3" "pi3 pi2"; do
  set -- $pair; me=$1; peer=$2; ip=$(leaf_ip $me)
  t0=$(date +%s)
  on_leaf $me "mkdir -p ~/lnmesh-ada/bin ~/lnmesh-ada/keys"
  # shellcheck disable=SC2086
  scp -q $SSH_OPTS hydrapay.py sockfwd.py extract-image.py contest-log.py protocol-parameters.json hydra-scripts.txid "$SSH_USER@$ip:~/lnmesh-ada/"
  # shellcheck disable=SC2086
  scp -q $SSH_OPTS hydra-node.sh "$SSH_USER@$ip:~/lnmesh-ada/bin/hydra-node"
  if ! on_leaf $me "test -f ~/lnmesh-ada/hydra-image/.ok"; then
    echo "-- hydra image to $me ($(du -h hydra-layer.tar.gz | cut -f1) compressed)"
    # shellcheck disable=SC2086
    scp -q $SSH_OPTS hydra-layer.tar.gz "$SSH_USER@$ip:~/lnmesh-ada/"
    on_leaf $me "cd ~/lnmesh-ada && python3 extract-image.py hydra-layer.tar.gz hydra-image && bin/hydra-node --version"
  fi
  if ! on_leaf $me "test -x ~/lnmesh-ada/bin/cardano-cli && test \$(stat -c %s ~/lnmesh-ada/bin/cardano-cli) -eq $(stat -L -c %s bin/cardano-cli)"; then
    echo "-- cardano-cli to $me ($(du -Lh bin/cardano-cli | cut -f1))"
    # shellcheck disable=SC2086
    scp -q $SSH_OPTS bin/cardano-cli "$SSH_USER@$ip:~/lnmesh-ada/bin/cardano-cli"
  fi
  if ! on_leaf $me "test -x ~/lnmesh-ada/venv/bin/python && ~/lnmesh-ada/venv/bin/python -c 'import pycardano, websocket'" 2>/dev/null; then
    echo "-- venv to $me ($(du -sh venv | cut -f1))"
    tar cz -C "$A" venv | on_leaf $me "rm -rf ~/lnmesh-ada/venv && tar xz -C ~/lnmesh-ada"
  fi
  # shellcheck disable=SC2086
  scp -q $SSH_OPTS keys/$me-node.sk keys/$me-node.vk keys/$me-funds.sk keys/$me-funds.vk keys/$me-hydra.sk keys/$me-hydra.vk \
    keys/$peer-node.vk keys/$peer-funds.vk keys/$peer-hydra.vk "$SSH_USER@$ip:~/lnmesh-ada/keys/"
  on_leaf $me "chmod 0600 ~/lnmesh-ada/keys/*.sk; rm -f ~/lnmesh-ada/keys/*-funds-utxo.json; ls ~/lnmesh-ada | tr '\n' ' '; echo; ~/lnmesh-ada/bin/cardano-cli --version | head -1"
  echo "-- $me done in $(( $(date +%s) - t0 )) s"
done
echo "done"
