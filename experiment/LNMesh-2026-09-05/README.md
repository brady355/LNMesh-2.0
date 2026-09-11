# LNMesh runbook

Offline Lightning channels over a Raspberry Pi mesh: three Pi 5s, batman-adv
over ad-hoc WiFi, A as the only node with internet, B and C with no cable at
all. B and C open, use, and close Lightning channels with every on-chain
byte relayed through A. Everything below is regtest.

- `PLAN.md`: why. Decisions, threat model, known gaps, follow-ups.
- `DOCUMENTATION.md`: how. Reproducible procedure from blank cards, with
  the observed result of every phase and demo.
- `results/2026-09-03/`: raw logs of every demo run, link measurements.
- `scripts/`, `units/`: everything that was run on the Pis.
- `hosts.env`: addresses, users, node pubkeys, RPC password (not for git).

## Quick reference

| Node | Role | Mesh | Management | Chain backend |
|---|---|---|---|---|
| A | gateway: bitcoind regtest, lnd, chrony, block filters | 10.10.0.1 | 192.168.0.130 (Ethernet) | bitcoind, local |
| B | offline: lnd | 10.10.0.2 | `ssh lnmesh-b` via ProxyJump A | Neutrino, peer A |
| C | offline: lnd | 10.10.0.3 | `ssh lnmesh-c` via ProxyJump A | Neutrino, peer A |

Run a demo: `./scripts/demo/N-name.sh`. Each prints every remote command
with a timestamp before running it and appends to `results/<date>/`.

## Results summary

| Demo | Result | Key numbers |
|---|---|---|
| 1 Offline funding | pass | B: 400,000 sat channel balance with 0 on-chain; B, C each +2,000,000 on-chain via A |
| 2 Offline open | pass | B-C funding tx in A's mempool in 1 s, confirmed at 114, active both sides 7 s after open |
| 3 Offline pay | pass | B->C, B->A, A->B all SUCCEEDED, 261 to 333 ms |
| 4 Offline close | pass (run 2) | coop close +400,000; force close, maturity 1008, sweep +986,263 |
| 5 No chain at all | pass (run 2, after Neutrino) | B->C SUCCEEDED in 256 ms with bitcoind stopped |
| 6 Breach response | pass | stale state at 2166, justice tx at 2167, B +984,230, C +0 |

Two demos failed on their first run and the fixes are part of the build:
Demo 4 (wallet not yet rescanned after 1008 blocks; retry added) and Demo 5
(LND with a bitcoind backend cannot start a payment while the backend is
down; B and C moved to Neutrino). Details in `DOCUMENTATION.md` Phase 7.

## Demo logs

Verbatim from `results/2026-09-03/`. Lines starting with `[time] x$` are
the commands as run on node x; everything else is output. Terminal control
sequences from `lncli` have been stripped.

### 1-fund

```

##### 1-fund start 2026-09-03T20:31:44-05:00
== Demo 1: offline funding
-- a: on-chain confirmed=10000000000 sat, channel local=0 sat, height=101
-- b: on-chain confirmed=0 sat, channel local=0 sat, height=101
-- c: on-chain confirmed=0 sat, channel local=0 sat, height=101
[20:31:50] a$ lncli-mesh openchannel --node_key 0273d7f102445b9bb25164fb53abe690816a622526e5c1591bf7ad98d39b8cfa51 --local_amt 1000000 --push_amt 400000 --private --sat_per_vbyte 1
{
    "funding_txid": "8d01d5db8ac1c2cba89b825dc980328085757adf454303880dc59c3a906c12a1"
}
A-B funding channel point: 8d01d5db8ac1c2cba89b825dc980328085757adf454303880dc59c3a906c12a1:0
[20:31:51] a$ bcli getrawmempool
[
  "8d01d5db8ac1c2cba89b825dc980328085757adf454303880dc59c3a906c12a1"
]
[20:31:51] a$ mine 6
A-B active on A
A-B active on B
>> B channel balance 400000 sat, B on-chain 0 sat  (balance with zero on-chain funds)
[20:31:58] b$ lncli-mesh newaddress p2tr   -> bcrt1p5szpxd858zhct640myyuwk8l73adjagzg0kgtmhkl7d8ml46scaqpvz6u6
[20:31:58] a$ lncli-mesh sendcoins --addr bcrt1p5szpxd858zhct640myyuwk8l73adjagzg0kgtmhkl7d8ml46scaqpvz6u6 --amt 2000000 --sat_per_vbyte 1
{
    "txid": "8ab09158ca430b8849b35c16598a4bf664e8dedf04917be302e68995c67c43c1"
}
[20:31:59] c$ lncli-mesh newaddress p2tr   -> bcrt1p4c56nyh9l83acl24pxu9d04rcfnf92y5jgfetlck5jlry3mqvz3qsw437p
[20:31:59] a$ lncli-mesh sendcoins --addr bcrt1p4c56nyh9l83acl24pxu9d04rcfnf92y5jgfetlck5jlry3mqvz3qsw437p --amt 2000000 --sat_per_vbyte 1
{
    "txid": "9f9b4631328b65aec1078e92fbb3fe67273e9fc582657fb7f27cb0e9ab2ee4c5"
}
[20:31:59] a$ bcli getrawmempool
[
  "9f9b4631328b65aec1078e92fbb3fe67273e9fc582657fb7f27cb0e9ab2ee4c5",
  "8ab09158ca430b8849b35c16598a4bf664e8dedf04917be302e68995c67c43c1"
]
[20:31:59] a$ mine 6
-- a: on-chain confirmed=69994999533 sat, channel local=596530 sat, height=113
-- b: on-chain confirmed=2000000 sat, channel local=400000 sat, height=113
-- c: on-chain confirmed=2000000 sat, channel local=0 sat, height=113
##### 1-fund end 2026-09-03T20:32:06-05:00
```

### 2-open

```

##### 2-open start 2026-09-03T20:32:21-05:00
== Demo 2: offline open
-- b: on-chain confirmed=2000000 sat, channel local=400000 sat, height=113
-- c: on-chain confirmed=2000000 sat, channel local=0 sat, height=113
[20:32:25] b$ lncli-mesh openchannel --node_key 03d2650dba1d9cc29b6d9f0d8b1c7bac437f884ef39dfa671d3198cb40e3e0f199 --local_amt 1000000  --private --sat_per_vbyte 1
{
    "funding_txid": "83c192cfe05615f8057575774057d03fbb22a76823a4ee7f3190980d08ba8b90"
}
>> B pendingchannels channel point: 83c192cfe05615f8057575774057d03fbb22a76823a4ee7f3190980d08ba8b90:1
[20:32:26] a$ bcli getrawmempool
[
  "83c192cfe05615f8057575774057d03fbb22a76823a4ee7f3190980d08ba8b90"
]
>> funding txid 83c192cfe05615f8057575774057d03fbb22a76823a4ee7f3190980d08ba8b90 is in A's mempool
[20:32:26] a$ mine 6
mined 6, height 119
>> funding tx confirmed at height 114
[20:32:32] b$ lncli-mesh listchannels | jq -c '.channels[] | {peer: .remote_pubkey[0:10], active, capacity, local_balance, channel_point}'
{"peer":"0216fff02e","active":true,"capacity":"1000000","local_balance":"400000","channel_point":"8d01d5db8ac1c2cba89b825dc980328085757adf454303880dc59c3a906c12a1:0"}
{"peer":"03d2650dba","active":true,"capacity":"1000000","local_balance":"996530","channel_point":"83c192cfe05615f8057575774057d03fbb22a76823a4ee7f3190980d08ba8b90:1"}
[20:32:32] c$ lncli-mesh listchannels | jq -c '.channels[] | {peer: .remote_pubkey[0:10], active, capacity, local_balance, channel_point}'
{"peer":"0273d7f102","active":true,"capacity":"1000000","local_balance":"0","channel_point":"83c192cfe05615f8057575774057d03fbb22a76823a4ee7f3190980d08ba8b90:1"}
[20:32:33] a$ lncli-mesh openchannel --node_key 03d2650dba1d9cc29b6d9f0d8b1c7bac437f884ef39dfa671d3198cb40e3e0f199 --local_amt 1000000 --push_amt 400000 --private --sat_per_vbyte 1
{
    "funding_txid": "11347494531fb5d28478817fa50173877a0ee5086505fe0609f705fd155c0e2f"
}
[20:32:34] a$ mine 6
mined 6, height 125
A-C active
-- a: on-chain confirmed=129993999378 sat, channel local=1193060 sat, height=125
-- b: on-chain confirmed=999845 sat, channel local=1396530 sat, height=125
-- c: on-chain confirmed=2000000 sat, channel local=400000 sat, height=125
##### 2-open end 2026-09-03T20:32:41-05:00
```

### 3-pay

```

##### 3-pay start 2026-09-03T20:32:50-05:00
== Demo 3: offline pay
[20:32:51] c$ lncli-mesh addinvoice --amt 10000 --memo 'B to C'   -> lnbcrt100u1p4f587rpp5m3u834uw00n...
[20:32:51] b$ lncli-mesh payinvoice --force lnbcrt...[invoice] 2>&1 | grep -vE '^\s*$' | tail -8
+------------+--------------+--------------+--------------+-----+----------+-----------------+----------+
| HTLC_STATE | ATTEMPT_TIME | RESOLVE_TIME | RECEIVER_AMT | FEE | TIMELOCK | CHAN_OUT        | ROUTE    |
+------------+--------------+--------------+--------------+-----+----------+-----------------+----------+
| SUCCEEDED  |        0.035 |        0.333 | 10000        | 0   |      208 | 125344325632001 | lnmesh-c |
+------------+--------------+--------------+--------------+-----+----------+-----------------+----------+
Amount + fee:   10000 + 0 sat
Payment hash:   dc7878d78e7be6f1122020cf754a4dbdb0349cfc87de65a8fe3aa29a4a3d1325
Payment status: SUCCEEDED, preimage: 0da729d26f14bf86dbae710a7032d152623864ee75925535d39ecfc2d6ef8b08
[20:32:52] a$ lncli-mesh addinvoice --amt 10000 --memo 'B to A'   -> lnbcrt100u1p4f587ypp5yh6xnzx50zz...
[20:32:52] b$ lncli-mesh payinvoice --force lnbcrt...[invoice] 2>&1 | grep -vE '^\s*$' | tail -8
+------------+--------------+--------------+--------------+-----+----------+-----------------+----------+
| HTLC_STATE | ATTEMPT_TIME | RESOLVE_TIME | RECEIVER_AMT | FEE | TIMELOCK | CHAN_OUT        | ROUTE    |
+------------+--------------+--------------+--------------+-----+----------+-----------------+----------+
| SUCCEEDED  |        0.025 |        0.262 | 10000        | 0   |      208 | 112150186098688 | lnmesh-a |
+------------+--------------+--------------+--------------+-----+----------+-----------------+----------+
Amount + fee:   10000 + 0 sat
Payment hash:   25f46988d47884145e9ca403fbcf64c04ba5671fe547112ff1b3f0b12db9cd95
Payment status: SUCCEEDED, preimage: 0ce300da172d31005dd3f9c4873f10a72e0e4848a2be5249338131cc16f4dec7
[20:32:53] b$ lncli-mesh addinvoice --amt 10000 --memo 'A to B'   -> lnbcrt100u1p4f5879pp52pamnt3rquu...
[20:32:53] a$ lncli-mesh payinvoice --force lnbcrt...[invoice] 2>&1 | grep -vE '^\s*$' | tail -8
+------------+--------------+--------------+--------------+-----+----------+-----------------+-------+
| HTLC_STATE | ATTEMPT_TIME | RESOLVE_TIME | RECEIVER_AMT | FEE | TIMELOCK | CHAN_OUT        | ROUTE |
+------------+--------------+--------------+--------------+-----+----------+-----------------+-------+
| SUCCEEDED  |        0.025 |        0.261 | 10000        | 0   |      208 | 112150186098688 |       |
+------------+--------------+--------------+--------------+-----+----------+-----------------+-------+
Amount + fee:   10000 + 0 sat
Payment hash:   507bb9ae2307399c58028b335c3ddd5406d16b7ca3b2458347e57c9c4b22e8a8
Payment status: SUCCEEDED, preimage: 25bba4eedca156105b79a5db5726fb2febfa25e8529e8e15722aa4cbc1ee24ae
[20:32:54] b$ lncli-mesh listpayments | jq -c '.payments[] | {value_sat, status, memo: (.htlcs[0].route.hops[-1].pub_key[0:10]), ms: (((.htlcs[0].resolve_time_ns|tonumber) - (.creation_time_ns|tonumber))/1e6|floor)}'
{"value_sat":"10000","status":"SUCCEEDED","memo":"03d2650dba","ms":333}
{"value_sat":"10000","status":"SUCCEEDED","memo":"0216fff02e","ms":262}
[20:32:54] a$ lncli-mesh listpayments | jq -c '.payments[] | {value_sat, status, ms: (((.htlcs[0].resolve_time_ns|tonumber) - (.creation_time_ns|tonumber))/1e6|floor)}'
{"value_sat":"10000","status":"SUCCEEDED","ms":261}
-- a: on-chain confirmed=129993999378 sat, channel local=1193060 sat, height=125
-- b: on-chain confirmed=999845 sat, channel local=1386530 sat, height=125
-- c: on-chain confirmed=2000000 sat, channel local=410000 sat, height=125
##### 3-pay end 2026-09-03T20:32:57-05:00
```

### 4-close

```

##### 4-close start 2026-09-03T20:33:05-05:00
== Demo 4: offline close
-- b: on-chain confirmed=999845 sat, channel local=1386530 sat, height=125
[20:33:07] b$ lncli-mesh closechannel --funding_txid 8d01d5db8ac1c2cba89b825dc980328085757adf454303880dc59c3a906c12a1 --output_index 0 --sat_per_vbyte 1 2>&1 | head -5
Channel close successfully initiated
Channel close transaction broadcasted: fd708e477a5d06a69a258e751a49c0c0d043a16f64fb19ab86e684df6b8b1218
{
    "closing_txid": "fd708e477a5d06a69a258e751a49c0c0d043a16f64fb19ab86e684df6b8b1218"
}
[20:33:09] a$ bcli getrawmempool
[
  "fd708e477a5d06a69a258e751a49c0c0d043a16f64fb19ab86e684df6b8b1218"
]
[20:33:09] a$ mine 1
mined 1, height 126
[20:33:13] b$ lncli-mesh closedchannels | jq -c '.channels[] | {peer: .remote_pubkey[0:10], close_type, closing_tx_hash, settled_balance, close_height}'
{"peer":"0216fff02e","close_type":"COOPERATIVE_CLOSE","closing_tx_hash":"fd708e477a5d06a69a258e751a49c0c0d043a16f64fb19ab86e684df6b8b1218","settled_balance":"400000","close_height":126}
>> B on-chain before coop close: 999845 sat, after: 1399845 sat
-- b: on-chain confirmed=1399845 sat, channel local=986530 sat, height=126
[20:33:16] b$ lncli-mesh closechannel --funding_txid 83c192cfe05615f8057575774057d03fbb22a76823a4ee7f3190980d08ba8b90 --output_index 1 --force 2>&1 | head -5
Channel close successfully initiated
Channel close transaction broadcasted: 01f59baf6dbbc13b9377fecd959766416be3175e591f2bcc17620f15c826c622
{
    "closing_txid": "01f59baf6dbbc13b9377fecd959766416be3175e591f2bcc17620f15c826c622"
}
[20:33:16] a$ bcli getrawmempool
[
  "01f59baf6dbbc13b9377fecd959766416be3175e591f2bcc17620f15c826c622"
]
[20:33:16] a$ mine 1
mined 1, height 127
[20:33:21] b$ lncli-mesh pendingchannels | jq -c '.pending_force_closing_channels[] | {closing_txid, blocks_til_maturity, limbo_balance, maturity_height}'
{"closing_txid":"01f59baf6dbbc13b9377fecd959766416be3175e591f2bcc17620f15c826c622","blocks_til_maturity":1008,"limbo_balance":"986860","maturity_height":1135}
>> mining 1008 blocks for the CSV delay
[20:33:21] a$ mine 1008
mined 1008, height 1135
[20:33:52] a$ bcli getrawmempool
[
  "5c41a91785e8077bf591d0eb46aea8d6c43aef16b899473cf34e523254cba77f"
]
[20:33:52] a$ mine 1
mined 1, height 1136
[20:34:02] b$ lncli-mesh pendingchannels | jq -c '{force_closing: .pending_force_closing_channels}'
{"force_closing":[]}
[20:34:02] b$ lncli-mesh closedchannels | jq -c '.channels[] | select(.close_type=="LOCAL_FORCE_CLOSE") | {peer: .remote_pubkey[0:10], close_type, closing_tx_hash, settled_balance, close_height}'
{"peer":"03d2650dba","close_type":"LOCAL_FORCE_CLOSE","closing_tx_hash":"01f59baf6dbbc13b9377fecd959766416be3175e591f2bcc17620f15c826c622","settled_balance":"986530","close_height":127}
>> B on-chain before force close: 1399845 sat, after sweep: 2386108 sat
-- b: on-chain confirmed=2386108 sat, channel local=0 sat, height=1136
== reopen B-C (from B) and A-B (from A, with push)
[20:34:04] b$ lncli-mesh openchannel --node_key 03d2650dba1d9cc29b6d9f0d8b1c7bac437f884ef39dfa671d3198cb40e3e0f199 --local_amt 1000000  --private --sat_per_vbyte 1
{
    "funding_txid": "eaf95fa6adfd2abd7110e4cf32fe943bb7cbe23c7aa5cc9653bd5c451f32bb4c"
}
[20:34:06] a$ lncli-mesh openchannel --node_key 0273d7f102445b9bb25164fb53abe690816a622526e5c1591bf7ad98d39b8cfa51 --local_amt 1000000 --push_amt 400000 --private --sat_per_vbyte 1
[lncli] rpc error: code = Unknown desc = channels cannot be created before the wallet is fully synced
[20:34:06] a$ mine 6
mined 6, height 1142
!! channel a-b not active after 60 s
-- a: on-chain confirmed=1482807103089 sat, channel local=596530 sat, height=1142
-- b: on-chain confirmed=1385894 sat, channel local=996530 sat, height=1142
-- c: on-chain confirmed=2009876 sat, channel local=400000 sat, height=1142
##### 4-close end 2026-09-03T20:35:20-05:00

##### 4-close start 2026-09-03T20:35:47-05:00
== Demo 4: offline close
== precondition: A-B and B-C must exist
[20:35:48] a$ lncli-mesh openchannel --node_key 0273d7f102445b9bb25164fb53abe690816a622526e5c1591bf7ad98d39b8cfa51 --local_amt 1000000 --push_amt 400000 --private --sat_per_vbyte 1
{
    "funding_txid": "81529ea4874e1998ac951cb93f1459fe239c7763888851ca1b35508c264f03cd"
}
[20:35:48] a$ mine 6
mined 6, height 1148
-- b: on-chain confirmed=1385894 sat, channel local=1396530 sat, height=1148
[20:35:55] b$ lncli-mesh closechannel --funding_txid 81529ea4874e1998ac951cb93f1459fe239c7763888851ca1b35508c264f03cd --output_index 0 --sat_per_vbyte 1 2>&1 | head -5
Channel close successfully initiated
Channel close transaction broadcasted: 5ba558bd8f37940ca6d423a6b52d995271e93b1212199a9f01602370139d8191
{
    "closing_txid": "5ba558bd8f37940ca6d423a6b52d995271e93b1212199a9f01602370139d8191"
}
[20:35:57] a$ bcli getrawmempool
[
  "5ba558bd8f37940ca6d423a6b52d995271e93b1212199a9f01602370139d8191"
]
[20:35:58] a$ mine 1
mined 1, height 1149
[20:36:02] b$ lncli-mesh closedchannels | jq -c '.channels[] | {peer: .remote_pubkey[0:10], close_type, closing_tx_hash, settled_balance, close_height}'
{"peer":"0216fff02e","close_type":"COOPERATIVE_CLOSE","closing_tx_hash":"fd708e477a5d06a69a258e751a49c0c0d043a16f64fb19ab86e684df6b8b1218","settled_balance":"400000","close_height":126}
{"peer":"03d2650dba","close_type":"LOCAL_FORCE_CLOSE","closing_tx_hash":"01f59baf6dbbc13b9377fecd959766416be3175e591f2bcc17620f15c826c622","settled_balance":"986530","close_height":127}
{"peer":"0216fff02e","close_type":"COOPERATIVE_CLOSE","closing_tx_hash":"5ba558bd8f37940ca6d423a6b52d995271e93b1212199a9f01602370139d8191","settled_balance":"400000","close_height":1149}
>> B on-chain before coop close: 1385894 sat, after: 1785894 sat
-- b: on-chain confirmed=1785894 sat, channel local=996530 sat, height=1149
[20:36:04] b$ lncli-mesh closechannel --funding_txid eaf95fa6adfd2abd7110e4cf32fe943bb7cbe23c7aa5cc9653bd5c451f32bb4c --output_index 1 --force 2>&1 | head -5
Channel close successfully initiated
Channel close transaction broadcasted: 8210270104f9362d3a16c99b72dbd306485a3b2f87bd2b5aaa49df711d33e16d
{
    "closing_txid": "8210270104f9362d3a16c99b72dbd306485a3b2f87bd2b5aaa49df711d33e16d"
}
[20:36:05] a$ bcli getrawmempool
[
  "8210270104f9362d3a16c99b72dbd306485a3b2f87bd2b5aaa49df711d33e16d"
]
[20:36:05] a$ mine 1
mined 1, height 1150
[20:36:09] b$ lncli-mesh pendingchannels | jq -c '.pending_force_closing_channels[] | {closing_txid, blocks_til_maturity, limbo_balance, maturity_height}'
{"closing_txid":"8210270104f9362d3a16c99b72dbd306485a3b2f87bd2b5aaa49df711d33e16d","blocks_til_maturity":1008,"limbo_balance":"996860","maturity_height":2158}
>> mining 1008 blocks for the CSV delay
[20:36:10] a$ mine 1008
mined 1008, height 2158
>> waiting for all wallets to rescan
[20:37:05] a$ bcli getrawmempool
[
  "f836e81344a311117d3a93bdf2d3e4d2d88d5a595b84c5adb8d66ea9c02ca8e8"
]
[20:37:05] a$ mine 1
mined 1, height 2159
[20:37:14] b$ lncli-mesh pendingchannels | jq -c '{force_closing: .pending_force_closing_channels}'
{"force_closing":[]}
[20:37:14] b$ lncli-mesh closedchannels | jq -c '.channels[] | select(.close_type=="LOCAL_FORCE_CLOSE") | {peer: .remote_pubkey[0:10], close_type, closing_tx_hash, settled_balance, close_height}'
{"peer":"03d2650dba","close_type":"LOCAL_FORCE_CLOSE","closing_tx_hash":"01f59baf6dbbc13b9377fecd959766416be3175e591f2bcc17620f15c826c622","settled_balance":"986530","close_height":127}
{"peer":"03d2650dba","close_type":"LOCAL_FORCE_CLOSE","closing_tx_hash":"8210270104f9362d3a16c99b72dbd306485a3b2f87bd2b5aaa49df711d33e16d","settled_balance":"996530","close_height":1150}
>> B on-chain before force close: 1785894 sat, after sweep: 2782157 sat
-- b: on-chain confirmed=2782157 sat, channel local=0 sat, height=2159
== reopen B-C (from B) and A-B (from A, with push)
[20:37:19] b$ lncli-mesh openchannel --node_key 03d2650dba1d9cc29b6d9f0d8b1c7bac437f884ef39dfa671d3198cb40e3e0f199 --local_amt 1000000  --private --sat_per_vbyte 1
{
    "funding_txid": "e6080378d0bbb1dfc7ba7aa88a640fe02224e1d08a0a9d00d9dca174f0c1fc32"
}
[20:37:21] a$ lncli-mesh openchannel --node_key 0273d7f102445b9bb25164fb53abe690816a622526e5c1591bf7ad98d39b8cfa51 --local_amt 1000000 --push_amt 400000 --private --sat_per_vbyte 1
{
    "funding_txid": "9aace155d2a5fab2e558ba3e201daef271c0a8d39796d51234c11c6e3e0b0eeb"
}
[20:37:21] a$ mine 6
mined 6, height 2165
B-C and A-B active again
-- a: on-chain confirmed=1494881512022 sat, channel local=1193060 sat, height=2165
-- b: on-chain confirmed=1781943 sat, channel local=1396530 sat, height=2165
-- c: on-chain confirmed=2009876 sat, channel local=400000 sat, height=2165
##### 4-close end 2026-09-03T20:37:28-05:00
```

### 5-baseline

```

##### 5-baseline start 2026-09-03T20:37:43-05:00
== Demo 5: pay with bitcoind stopped
[20:37:43] a$ sudo systemctl stop bitcoind
[20:37:46] a$ systemctl is-active bitcoind || true
inactive
[20:37:49] c$ lncli-mesh addinvoice --amt 5000 --memo 'B to C with bitcoind stopped'   -> lnbcrt50u1p4f5g8dpp54k980vxqv55c...
[20:37:49] b$ lncli-mesh payinvoice --force lnbcrt...[invoice] 2>&1 | grep -vE '^\s*$' | tail -8
+------------+--------------+--------------+--------------+-----+----------+----------+-------+
| HTLC_STATE | ATTEMPT_TIME | RESOLVE_TIME | RECEIVER_AMT | FEE | TIMELOCK | CHAN_OUT | ROUTE |
+------------+--------------+--------------+--------------+-----+----------+----------+-------+
+------------+--------------+--------------+--------------+-----+----------+----------+-------+
Amount + fee:   0 + 0 sat
Payment hash:   ad8a77b0c06529865df57e32ff860aee4e1e4a68df87885a7dd0223bc4cffab9
Payment status: IN_FLIGHT
[lncli] rpc error: code = Unknown desc = routerrpc server shutting down
[20:43:07] b$ lncli-mesh listpayments | jq -c '.payments[-1] | {value_sat, status}'
[lncli] rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial tcp 127.0.0.1:10009: connect: connection refused"
[20:43:08] a$ sudo systemctl start bitcoind

##### 5-baseline start 2026-09-03T20:51:29-05:00
== Demo 5: pay with bitcoind stopped
[20:51:30] a$ sudo systemctl stop bitcoind
[20:51:34] a$ systemctl is-active bitcoind || true
inactive
[20:51:35] c$ lncli-mesh addinvoice --amt 5000 --memo 'B to C with bitcoind stopped'   -> lnbcrt50u1p4f5fp8pp5k4u6grdkj8sr...
[20:51:35] b$ lncli-mesh payinvoice --force lnbcrt...[invoice] 2>&1 | grep -vE '^\s*$' | tail -8
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
| HTLC_STATE | ATTEMPT_TIME | RESOLVE_TIME | RECEIVER_AMT | FEE | TIMELOCK | CHAN_OUT         | ROUTE |
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
| SUCCEEDED  |        0.032 |        0.281 | 5000         | 0   |     2248 | 2374945116061697 |       |
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
Amount + fee:   5000 + 0 sat
Payment hash:   b579a40db691e030bc871ef08a71d1653d819b34a2bc27285b84acdd58508dc0
Payment status: SUCCEEDED, preimage: 164923a944e6df966af294b92e21c89e540f98c184fe3a8980d1008de182f042
[20:51:35] b$ lncli-mesh listpayments | jq -c '.payments[-1] | {value_sat, status}'
{"value_sat":"5000","status":"SUCCEEDED"}
[20:51:36] a$ sudo systemctl start bitcoind
[20:54:01] a$ lncli-mesh getinfo | jq -c '{alias, synced_to_chain, block_height}'
[lncli] rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial tcp 127.0.0.1:10009: connect: connection refused"
[20:54:02] b$ lncli-mesh getinfo | jq -c '{alias, synced_to_chain, block_height}'
{"alias":"lnmesh-b","synced_to_chain":true,"block_height":2165}
[20:54:02] c$ lncli-mesh getinfo | jq -c '{alias, synced_to_chain, block_height}'
{"alias":"lnmesh-c","synced_to_chain":true,"block_height":2165}
##### 5-baseline end 2026-09-03T20:54:02-05:00

##### 5-baseline start 2026-09-03T20:54:38-05:00
== Demo 5: pay with bitcoind stopped
[20:54:38] a$ sudo systemctl stop bitcoind
[20:54:42] a$ systemctl is-active bitcoind || true
inactive
[20:54:42] c$ lncli-mesh addinvoice --amt 5000 --memo 'B to C with bitcoind stopped'   -> lnbcrt50u1p4f5f8zpp50jjlkq2np3eq...
[20:54:42] b$ lncli-mesh payinvoice --force lnbcrt...[invoice] 2>&1 | grep -vE '^\s*$' | tail -8
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
| HTLC_STATE | ATTEMPT_TIME | RESOLVE_TIME | RECEIVER_AMT | FEE | TIMELOCK | CHAN_OUT         | ROUTE |
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
| SUCCEEDED  |        0.019 |        0.256 | 5000         | 0   |     2248 | 2374945116061697 |       |
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
Amount + fee:   5000 + 0 sat
Payment hash:   7ca5fb01530c720dad3e1e3e406f8fa9095e4f46e4c337665f32d94174545a67
Payment status: SUCCEEDED, preimage: cd68928ad99690d394251325f3dfee45b213cf1afccb417c1dfbda3619d286d4
[20:54:43] b$ lncli-mesh listpayments | jq -c '.payments[-1] | {value_sat, status}'
{"value_sat":"5000","status":"SUCCEEDED"}
[20:54:43] a$ sudo systemctl start bitcoind
[20:54:54] a$ lncli-mesh getinfo | jq -c '{alias, synced_to_chain, block_height}'
{"alias":"lnmesh-a","synced_to_chain":true,"block_height":2165}
[20:54:55] b$ lncli-mesh getinfo | jq -c '{alias, synced_to_chain, block_height}'
{"alias":"lnmesh-b","synced_to_chain":true,"block_height":2165}
[20:54:55] c$ lncli-mesh getinfo | jq -c '{alias, synced_to_chain, block_height}'
{"alias":"lnmesh-c","synced_to_chain":true,"block_height":2165}
##### 5-baseline end 2026-09-03T20:54:55-05:00
```

### 6-breach

```

##### 6-breach start 2026-09-03T20:55:12-05:00
== Demo 6: breach response (regtest only)
regtest confirmed on bitcoind and all three lnd
-- b: on-chain confirmed=1781943 sat, channel local=1386530 sat, height=2165
-- c: on-chain confirmed=2009876 sat, channel local=410000 sat, height=2165
>> B-C capacity 1000000 sat
== snapshot C's channel.db
[20:55:19] c$ sudo systemctl stop lnd
[20:55:20] c$ sudo cp /var/lib/lnd/data/graph/regtest/channel.db /root/channel.db.stale && ls -l /root/channel.db.stale
ls: cannot access '/root/channel.db.stale': Permission denied
[20:55:20] c$ sudo systemctl start lnd
== advance the channel state (B pays C three times)
[20:55:25] c$ lncli-mesh addinvoice --amt 50000 --memo 'advance state 1'   -> lnbcrt500u1p4f5fgdpp5dhrqzv7r9rw...
[20:55:25] b$ lncli-mesh payinvoice --force lnbcrt...[invoice] 2>&1 | grep -vE '^\s*$' | tail -8
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
| HTLC_STATE | ATTEMPT_TIME | RESOLVE_TIME | RECEIVER_AMT | FEE | TIMELOCK | CHAN_OUT         | ROUTE |
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
| SUCCEEDED  |        0.024 |        0.239 | 50000        | 0   |     2248 | 2374945116061697 |       |
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
Amount + fee:   50000 + 0 sat
Payment hash:   6dc60133c328dd5aa921474b03bfdcad92dc103266507d45d33050dca379b0e5
Payment status: SUCCEEDED, preimage: 283d514b0d230ec94b5bbcec0539a444e02fb35ac5e96cd2d1fae91c720f321e
[20:55:25] c$ lncli-mesh addinvoice --amt 50000 --memo 'advance state 2'   -> lnbcrt500u1p4f5fgdpp5mkd2qysqur2...
[20:55:25] b$ lncli-mesh payinvoice --force lnbcrt...[invoice] 2>&1 | grep -vE '^\s*$' | tail -8
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
| HTLC_STATE | ATTEMPT_TIME | RESOLVE_TIME | RECEIVER_AMT | FEE | TIMELOCK | CHAN_OUT         | ROUTE |
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
| SUCCEEDED  |        0.021 |        0.237 | 50000        | 0   |     2248 | 2374945116061697 |       |
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
Amount + fee:   50000 + 0 sat
Payment hash:   dd9aa01200e0d4f27bc9088f950fb5df1c8b05653ad68ff87f90b1fedf51c8eb
Payment status: SUCCEEDED, preimage: 8c56d014f06c44d03ae5c0138cf9e45ee04586e34466d8cdf72a0857cc928dc8
[20:55:26] c$ lncli-mesh addinvoice --amt 50000 --memo 'advance state 3'   -> lnbcrt500u1p4f5fgwpp59jsj3dwtuyd...
[20:55:26] b$ lncli-mesh payinvoice --force lnbcrt...[invoice] 2>&1 | grep -vE '^\s*$' | tail -8
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
| HTLC_STATE | ATTEMPT_TIME | RESOLVE_TIME | RECEIVER_AMT | FEE | TIMELOCK | CHAN_OUT         | ROUTE |
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
| SUCCEEDED  |        0.022 |        0.246 | 50000        | 0   |     2248 | 2374945116061697 |       |
+------------+--------------+--------------+--------------+-----+----------+------------------+-------+
Amount + fee:   50000 + 0 sat
Payment hash:   2ca128b5cbe11aab7d5baa8ca3082919cf2d48dddd0e7ecb7c4c10e2a2dcc8c0
Payment status: SUCCEEDED, preimage: 4d64b2b8e2efc58f97b70e4b31b1ec1072363454796c402e5c2808cb8690efda
-- b: on-chain confirmed=1781943 sat, channel local=1236530 sat, height=2165
-- c: on-chain confirmed=2009876 sat, channel local=560000 sat, height=2165
== B goes away
[20:55:30] b$ sudo systemctl stop lnd
== C rewinds to the stale state and force-closes
[20:55:31] c$ sudo systemctl stop lnd
[20:55:31] c$ sudo cp /root/channel.db.stale /var/lib/lnd/data/graph/regtest/channel.db && sudo chown lnd:lnd /var/lib/lnd/data/graph/regtest/channel.db
[20:55:31] c$ sudo systemctl start lnd
[20:55:34] c$ lncli-mesh listchannels | jq -c '.channels[] | {peer: .remote_pubkey[0:10], active, local_balance, remote_balance}'
{"peer":"0216fff02e","active":false,"local_balance":"400000","remote_balance":"596530"}
{"peer":"0273d7f102","active":false,"local_balance":"10000","remote_balance":"986530"}
[20:55:35] c$ lncli-mesh closechannel --funding_txid e6080378d0bbb1dfc7ba7aa88a640fe02224e1d08a0a9d00d9dca174f0c1fc32 --output_index 1 --force 2>&1 | head -5
Channel close successfully initiated
Channel close transaction broadcasted: 3df654c9511d29a9e476d23df2de6150adbf9466d33436b8c68dce1e62c21796
{
    "closing_txid": "3df654c9511d29a9e476d23df2de6150adbf9466d33436b8c68dce1e62c21796"
}
>> A mempool holds stale commitment: 3df654c9511d29a9e476d23df2de6150adbf9466d33436b8c68dce1e62c21796
[20:55:44] a$ mine 1
mined 1, height 2166
>> stale commitment confirmed at height 2166
== B returns
[20:55:48] b$ sudo systemctl start lnd
[20:55:54] b$ sudo journalctl -u lnd --since -10min --no-pager | grep -iE 'breach|justice' | cut -c1-200 | head -8
Sep 03 20:50:29 lnmesh-b lnd[5416]: 2026-09-03 20:50:29.275 [INF] BRAR: Breach arbiter starting
Sep 03 20:50:29 lnmesh-b lnd[5416]: 2026-09-03 20:50:29.277 [INF] BRAR: Starting contract observer, watching for breaches.
Sep 03 20:51:10 lnmesh-b lnd[5416]: 2026-09-03 20:51:10.734 [INF] BRAR: Breach arbiter shutting down...
Sep 03 20:51:14 lnmesh-b lnd[5778]: 2026-09-03 20:51:14.223 [INF] BRAR: Breach arbiter starting
Sep 03 20:51:14 lnmesh-b lnd[5778]: 2026-09-03 20:51:14.224 [INF] BRAR: Starting contract observer, watching for breaches.
Sep 03 20:55:30 lnmesh-b lnd[5778]: 2026-09-03 20:55:30.787 [INF] BRAR: Breach arbiter shutting down...
Sep 03 20:55:52 lnmesh-b lnd[6386]: 2026-09-03 20:55:52.179 [INF] BRAR: Breach arbiter starting
Sep 03 20:55:52 lnmesh-b lnd[6386]: 2026-09-03 20:55:52.180 [INF] BRAR: Starting contract observer, watching for breaches.
>> A mempool holds justice tx: d2f884a7ae9c02776a984134bb56f40abe9d77308af7fef6c19eda7898c5c29d
[20:55:55] a$ mine 1
mined 1, height 2167
>> justice tx confirmed at height 2167 (gap 1 block)
[20:56:04] b$ lncli-mesh closedchannels | jq -c '.channels[] | select(.close_type=="BREACH_CLOSE") | {peer: .remote_pubkey[0:10], close_type, closing_tx_hash, settled_balance, close_height}'
{"peer":"03d2650dba","close_type":"BREACH_CLOSE","closing_tx_hash":"3df654c9511d29a9e476d23df2de6150adbf9466d33436b8c68dce1e62c21796","settled_balance":"836530","close_height":2166}
-- b: on-chain confirmed=2766173 sat, channel local=400000 sat, height=2167
-- c: on-chain confirmed=2009876 sat, channel local=400000 sat, height=2167
>> B wallet after breach: 2766173 sat. Capacity was 1000000 sat.
== cleanup: reset C (section 8.3), close A-C from A, refund and reopen
[20:56:09] c$ sudo systemctl stop lnd && sudo rm -rf /var/lib/lnd/data /var/lib/lnd/logs && sudo systemctl start lnd
>> C new identity 03f9d3bf6701ef5446dc12a977f4ffc7bcd5fa2f6708629a71b71b60ac815bd14d
[20:56:28] a$ lncli-mesh sendcoins --addr bcrt1pex99ye5ph2fgptgv6c74jrn7yy9xamtg9tqyl7ps793s3z84s3wsg7tzpv --amt 2000000 --sat_per_vbyte 1
{
    "txid": "c93eda415db1f08febfcca1c58b531d7b9c35b8368b0c8164b251c7a35301ac2"
}
[20:56:29] a$ mine 6
mined 6, height 2173
[20:56:37] b$ lncli-mesh openchannel --node_key 03f9d3bf6701ef5446dc12a977f4ffc7bcd5fa2f6708629a71b71b60ac815bd14d --local_amt 1000000  --private --sat_per_vbyte 1
{
    "funding_txid": "afd18fce3c57a6a81275b5ffc706f63d0370b335235bc22ed1e3e6eabc5ad353"
}
[20:56:39] a$ lncli-mesh openchannel --node_key 03f9d3bf6701ef5446dc12a977f4ffc7bcd5fa2f6708629a71b71b60ac815bd14d --local_amt 1000000 --push_amt 400000 --private --sat_per_vbyte 1
{
    "funding_txid": "279db9ff929c430f3fd2c229de669376b19daf656edfe4f54c6c4f3c1460aaba"
}
[20:56:39] a$ mine 6
mined 6, height 2179
B-C and A-C open again
-- a: on-chain confirmed=1494887056625 sat, channel local=1789590 sat, height=2179
-- b: on-chain confirmed=1765959 sat, channel local=1396530 sat, height=2179
-- c: on-chain confirmed=2000000 sat, channel local=400000 sat, height=2179
##### 6-breach end 2026-09-03T20:56:48-05:00
```

### Link measurements

```
# Mesh link measurements 2026-09-03T20:28:40-05:00

## batman-adv originators (TQ of 255) and RTT
### from a
  2c:cf:67:a8:95:63 TQ=(251)
  2c:cf:67:c1:a0:46 TQ=(255)
  ping 10.10.0.2:  5.730/6.622/7.936/0.603 ms
  ping 10.10.0.3:  0.743/5.380/6.770/1.864 ms
### from b
  2c:cf:67:f4:eb:83 TQ=(255)
  2c:cf:67:c1:a0:46 TQ=(255)
  ping 10.10.0.1:  0.751/5.249/6.793/2.256 ms
  ping 10.10.0.3:  0.688/5.417/8.308/2.355 ms
### from c
  2c:cf:67:a8:95:63 TQ=(255)
  2c:cf:67:f4:eb:83 TQ=(255)
  ping 10.10.0.1:  0.669/4.311/7.406/2.597 ms
  ping 10.10.0.2:  0.802/5.951/8.140/2.005 ms

## iperf3 B -> A over bat0 (10 s, TCP)
iperf3: error while loading shared libraries: libsctp.so.1: cannot open shared object file: No such file or directory

## iperf3 B -> A over bat0 (10 s, TCP)
[  5]   0.00-10.00  sec  59.5 MBytes  49.9 Mbits/sec    0            sender
[  5]   0.00-10.02  sec  56.9 MBytes  47.6 Mbits/sec                  receiver
```
