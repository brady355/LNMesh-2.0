#!/usr/bin/env bash
# Runs on the gateway. Builds the Python environment of the arm, creates the
# two leaf wallets, funds them from the genesis account of the stand-alone
# ledger and copies the environment, the node program and the key files to the
# leaves over the mesh. The leaves compile nothing. SKIP_FUND=1 skips the
# funding step.
set -euo pipefail
. "$HOME/testbed.env"
E=$HOME/lnmesh-xrp
RPC=${RPC:-http://127.0.0.1:5005}
FUND_XRP=${FUND_XRP:-10000}
cd "$E"
PY=$E/venv/bin/python
X="$PY $E/xrppay.py"

echo "== python venv =="
if [ ! -x venv/bin/python ] || ! venv/bin/python -c 'import xrpl' 2>/dev/null; then
  python3 -m venv venv && venv/bin/pip install -q xrpl-py
fi
venv/bin/pip show xrpl-py | grep -E '^(Name|Version)' | tr '\n' ' '; echo

echo "== wallets =="
for n in pi2 pi3; do
  [ -f $n.json ] || $X keygen -out $n.json -pub $n.pub
  echo "$n: $(python3 -c "import json;print(json.load(open('$n.pub'))['address'])")"
done

if [ "${SKIP_FUND:-0}" != 1 ]; then
  echo "== funding from genesis =="
  for n in pi2 pi3; do
    addr=$(python3 -c "import json;print(json.load(open('$n.pub'))['address'])")
    $X fund -rpc $RPC -to $addr -xrp $FUND_XRP
  done
fi

echo "== distributing =="
for pair in "pi2 pi3" "pi3 pi2"; do
  set -- $pair; me=$1; peer=$2; ip=$(leaf_ip $me)
  on_leaf $me "mkdir -p ~/lnmesh-xrp"
  if ! on_leaf $me "test -x ~/lnmesh-xrp/venv/bin/python && ~/lnmesh-xrp/venv/bin/python -c 'import xrpl'" 2>/dev/null; then
    echo "-- venv to $me"
    tar cz -C "$E" venv | on_leaf $me "rm -rf ~/lnmesh-xrp/venv && tar xz -C ~/lnmesh-xrp"
  fi
  # shellcheck disable=SC2086
  scp -q $SSH_OPTS "$E/xrppay.py" $me.json $peer.pub "$SSH_USER@$ip:~/lnmesh-xrp/"
  on_leaf $me "ls ~/lnmesh-xrp | grep -v venv | tr '\n' ' '; echo; ~/lnmesh-xrp/venv/bin/python ~/lnmesh-xrp/xrppay.py --help | head -1"
done
echo "done"
