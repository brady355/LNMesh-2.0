# LNMesh: headline findings

Experiment: 7-8 September 2026 UTC | Three Raspberry Pi 5s | Bitcoin regtest

**Two Pis without an internet route completed funding, channel opening, payments, closing, and breach response through a mesh gateway using stock Bitcoin Core and LND.**

A = pi1gateway; B = pi2; C = pi3. B and C used Neutrino with A as their sole Bitcoin peer over onboard Wi-Fi and batman-adv. The devices were a few inches apart on one table.

| Finding | Observed result |
| --- | --- |
| Funding and opening | B and C each received 2,000,000 sat on-chain; B opened a 1,000,000-sat channel to C. B also received 400,000 sat of channel balance while its on-chain wallet was zero. |
| Payments and chain outage | 150/150 measured payments settled. This included 30/30 while Bitcoin Core was stopped and the leaves' chain height stayed unchanged. |
| Both closure types | B recovered 400,000 sat cooperatively and 696,263 sat after a force close and its 1,008-block delay. |
| Breach response | A disposable node published revoked state at height 1155. B's justice transaction confirmed at 1156, recovering 484,230 sat from both principal outputs. |
| Connectivity and recovery | 600/600 ICMP packets arrived. Mean TCP throughput by tested direction ranged from 25.64 to 39.36 Mbit/s (three trials each). All three Pis recovered after individual reboots following a persistent-MAC fix. |

| Payment direction | Amount (sat) | Condition | Settled | Median (ms) |
| --- | --- | --- | --- | --- |
| B to C | 10,000 | Core running | 30/30 | 352 |
| B to A | 10,000 | Core running | 30/30 | 419 |
| A to B | 10,000 | Core running | 30/30 | 409 |
| B to C | 5,000 | Core running | 30/30 | 291 |
| B to C | 5,000 | Core stopped | 30/30 | 289 |

Timing is median local CLI payment duration, including process/RPC work and settlement; it excludes SSH setup and invoice creation. All measured routes used one hop and zero routing fees. The 291 vs 289 ms matched medians do not establish an outage performance benefit.

Scope: one close-range, sequential regtest deployment. Leaf isolation was software-enforced; Ethernet cables remained attached. No forced multi-hop path, field range, hostile gateway, or mainnet behavior was tested. The one-block justice gap reflects manually mined regtest blocks.

Evidence: four early preflight/install stdout records were damaged by filename collisions; preflight was repeated. Payment and channel results were unaffected. The full report documents these defects, recovery fixes, and raw evidence.

At the final checkpoint (8 September, 00:12:28 UTC), the original three-node triangle had three active channels; a further post-reboot payment settled. All amounts are simulated regtest satoshis.

Source: [full report](LNMesh-research-writeup.pdf), [analysis](analysis.json), and [recorded outcomes](../evidence/outcomes.jsonl).
