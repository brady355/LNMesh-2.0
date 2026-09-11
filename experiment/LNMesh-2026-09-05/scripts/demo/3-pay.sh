#!/usr/bin/env bash
# Demo 3: offline payments B->C, B->A, A->B.
source "$(dirname "$0")/lib.sh"
echo "== Demo 3: offline pay"
pay b c 10000 "B to C"
pay b a 10000 "B to A"
pay a b 10000 "A to B"
run b "lncli-mesh listpayments | jq -c '.payments[] | {value_sat, status, memo: (.htlcs[0].route.hops[-1].pub_key[0:10]), ms: (((.htlcs[0].resolve_time_ns|tonumber) - (.creation_time_ns|tonumber))/1e6|floor)}'"
run a "lncli-mesh listpayments | jq -c '.payments[] | {value_sat, status, ms: (((.htlcs[0].resolve_time_ns|tonumber) - (.creation_time_ns|tonumber))/1e6|floor)}'"
for h in a b c; do show $h; done
done_msg
