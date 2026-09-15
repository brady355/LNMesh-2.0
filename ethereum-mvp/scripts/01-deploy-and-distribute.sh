#!/usr/bin/env bash
# Runs on the gateway. Builds perunpay, deploys the Perun contracts on the
# local anvil chain, creates the wire identities and copies the binary and the
# key files to the two leaves over the mesh. The leaves compile nothing.
set -euo pipefail
. "$HOME/testbed.env"
export PATH=$HOME/sdk/go/bin:$HOME/bin:$HOME/.foundry/bin:$PATH
E=$HOME/lnmesh-eth
cd "$E"

echo "== building perunpay =="
(cd perunpay && go build -o "$HOME/bin/perunpay" .)
ls -la "$HOME/bin/perunpay" | awk '{print "binary bytes", $5}'

# These are the default anvil accounts of the test mnemonic. Account 0 deploys
# the contracts, account 1 belongs to pi2, account 2 to pi3 and account 3 to
# the tower.
KEY0=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

if [ ! -f contracts.json ]; then
  echo "== deploying contracts =="
  perunpay deploy -rpc ws://127.0.0.1:8545 -chainid 1337 -key $KEY0 -out contracts.json
fi
cat contracts.json

for n in pi2 pi3; do
  [ -f $n.wire ] || perunpay keygen -name $n -out $n.wire -pub $n.pub
done

echo "== distributing =="
for pair in "pi2 pi3" "pi3 pi2"; do
  set -- $pair; me=$1; peer=$2; ip=$(leaf_ip $me)
  on_leaf $me "pkill -x perunpay; mkdir -p ~/bin ~/lnmesh-eth"   # a running binary cannot be overwritten
  # shellcheck disable=SC2086
  scp -q $SSH_OPTS "$HOME/bin/perunpay" "$SSH_USER@$ip:~/bin/perunpay"
  # shellcheck disable=SC2086
  scp -q $SSH_OPTS $me.wire $peer.pub contracts.json "$SSH_USER@$ip:~/lnmesh-eth/"
  on_leaf $me "ls ~/lnmesh-eth | tr '\n' ' '; echo; ~/bin/perunpay 2>&1 | tail -1"
done
echo "done"
