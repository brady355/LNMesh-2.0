# LNMesh measurements, 2026-09-03

All from `results/2026-09-03/*.log` and `link.md`. Regtest; block times are
whatever `mine` on A produces, so anything that spans a mine measures the
gateway and mesh, not Bitcoin.

## Mesh link (batman-adv over IBSS, channel 1, 20 MHz)

| Pair | TQ (of 255) | RTT min / avg / max ms (10 pings) |
|---|---|---|
| A - B | 251 / 255 | 0.75 / 5.2 / 7.9 |
| A - C | 255 / 255 | 0.67 / 4.3 / 7.4 |
| B - C | 255 / 255 | 0.69 / 5.4 / 8.3 |

TQ shown from each end. All three pairs are direct one-hop links.

iperf3 B -> A over bat0, TCP, 10 s: 49.9 Mbit/s sender, 47.6 Mbit/s receiver,
0 retransmits.

## Open-to-confirm (Demo 1, Demo 2)

| Channel | `openchannel` | in A's mempool | `mine 6` | active both sides | wall time |
|---|---|---|---|---|---|
| A-B (Demo 1) | 20:31:50 | 20:31:51 | 20:31:51 | 20:31:57 | 7 s |
| B-C (Demo 2) | 20:32:25 | 20:32:26 | 20:32:26 | 20:32:32 | 7 s |

Broadcast from an offline node to A's mempool over the mesh: about 1 s.
The rest is LND noticing six blocks and the two peers exchanging
`channel_ready`.

## Payment latency (creation to HTLC resolve, from `listpayments` and `payinvoice`)

| Payment | Amount | Latency | Chain backend state |
|---|---|---|---|
| B -> C (Demo 3) | 10,000 | 333 ms | up |
| B -> A (Demo 3) | 10,000 | 262 ms | up |
| A -> B (Demo 3) | 10,000 | 261 ms | up |
| B -> C (Demo 5, run 2) | 5,000 | 256 ms | **bitcoind on A stopped** |
| B -> C x3 (Demo 6) | 50,000 | 239, 237, 246 ms | up |

Mean over one-hop mesh: about 260 ms. Payment latency did not change with
the chain backend down, which is the point of Demo 5.

## Close and sweep (Demo 4, run 2)

| Event | Height | Note |
|---|---|---|
| coop close broadcast by B | 1148 | in A's mempool within 2 s |
| coop close confirmed | 1149 | B +400,000 sat |
| force close broadcast by B | 1149 | |
| force close confirmed | 1150 | `blocks_til_maturity` 1008, `maturity_height` 2158 |
| sweep in A's mempool | 2158 | within 30 s of maturity |
| sweep confirmed | 2159 | B +986,263 sat |

## Breach response (Demo 6)

| Event | Height | Time |
|---|---|---|
| stale commitment (state #4) broadcast by C, B offline | 2165 | 20:55:35 |
| stale commitment confirmed via A | 2166 | 20:55:44 |
| B's lnd starts | 2166 | 20:55:48 |
| B logs "Revoked state #4 was broadcast" | 2166 | 20:55:52 (4 s after start) |
| justice tx in A's mempool | 2166 | 20:55:52 |
| justice tx confirmed | 2167 | 20:55:55 |

Block gap between stale commit and justice tx: 1. B recovered 984,230 of
the 1,000,000 sat capacity; C's on-chain balance did not change. B was a
Neutrino client and detected the breach from compact block filters served
by A.

## Failures observed and fixed

| Demo | Failure | Fix |
|---|---|---|
| 4, run 1 | A: "channels cannot be created before the wallet is fully synced" right after `mine 1008` | wait for `synced_to_chain`, retry open up to 6 times |
| 5, run 1 | B payment `IN_FLIGHT` forever: router's `getblockchaininfo` to A's stopped bitcoind failed; 5 min later all three lnds exited on the chain health check and did not restart | B, C to Neutrino with A as sole peer; `Restart=always`; A's unit `Wants=` not `Requires=` bitcoind |
| 6, cleanup | old A-C channel orphaned after C's identity reset | close it before the reset |
