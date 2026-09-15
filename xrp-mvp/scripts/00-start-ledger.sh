#!/usr/bin/env bash
# Runs on the gateway. Starts a fresh stand-alone xrpld ledger and the loop
# that closes a ledger every INTERVAL seconds. The default interval of 4 s
# follows the public XRP Ledger. The script writes the xrpld configuration
# first, so the database paths follow the home directory of the gateway user.
# Requests from 127.0.0.1 carry admin rights and requests from the mesh are
# public. Thus the leaves can read the ledger and submit transactions, but only
# the gateway can close ledgers. The script wipes any previous ledger, so run
# 01-setup-and-distribute.sh again afterwards to fund the leaf accounts.
#   00-start-ledger.sh [intervalSeconds]
set -euo pipefail
. "$HOME/testbed.env"
E=$HOME/lnmesh-xrp
XRPLD=${XRPLD:-$HOME/bin/xrpld}
INTERVAL=${1:-4}

pkill -f '[l]edger-loop.py' || true
pkill -f '[b]in/xrpld' || true   # xrpld renames its main thread, so the command line is the reliable match
sleep 1
rm -rf "$E/xrpld/db" "$E/xrpld/debug.log"
mkdir -p "$E/xrpld/db" "$E/logs"
: > "$E/logs/xrpld.out"

cat > "$E/xrpld.cfg" <<CFG
[server]
port_rpc
port_ws

[port_rpc]
port = 5005
ip = 0.0.0.0
admin = 127.0.0.1
protocol = http

[port_ws]
port = 6006
ip = 0.0.0.0
admin = 127.0.0.1
protocol = ws

[node_size]
small

[node_db]
type=NuDB
path=$E/xrpld/db/nudb

[database_path]
$E/xrpld/db

[debug_logfile]
$E/xrpld/debug.log

[ssl_verify]
0

[rpc_startup]
{ "command": "log_level", "severity": "warning" }
CFG

setsid -f bash -c "exec $XRPLD -a --start --conf $E/xrpld.cfg >> $E/logs/xrpld.out 2>&1 < /dev/null"
echo "waiting for xrpld RPC..."
for i in $(seq 60); do
  if curl -s -m 2 -X POST http://127.0.0.1:5005 -H 'Content-Type: application/json' \
       -d '{"method":"server_info","params":[{}]}' | grep -q build_version; then break; fi
  sleep 1
done
setsid -f bash -c "exec python3 $E/ledger-loop.py http://127.0.0.1:5005 $INTERVAL >> $E/logs/ledger-loop.log 2>&1 < /dev/null"
sleep $((INTERVAL + 1))
curl -s -m 5 -X POST http://127.0.0.1:5005 -H 'Content-Type: application/json' \
  -d '{"method":"server_info","params":[{}]}' | python3 -c '
import sys, json
i = json.load(sys.stdin)["result"]["info"]
v = i.get("validated_ledger", {})
print("xrpld", i.get("build_version"), "state", i.get("server_state"), "validated ledger", v.get("seq"),
      "reserve_base", v.get("reserve_base_xrp"), "reserve_inc", v.get("reserve_inc_xrp"), "fee", v.get("base_fee_xrp"))'
echo "public RPC for the leaves: http://$GW_IP:5005, one ledger every ${INTERVAL} s"
