# LNMesh 2.0 Roadmap (MVP)

Baseline: three Raspberry Pi 5 nodes (a gateway, b and c leaves) on one
batman-adv IBSS mesh. Gateway runs Bitcoin Core regtest and LND. Leaves run
LND with Neutrino pointed at the gateway. Code in `LNMesh-2.0/experiment/`.

Scope for this iteration: two changes, nothing else.

Status (13 September 2026): both items deployed and verified on lnmesh-a/b/c
with the scripts in `mvp/`. Old LND state is kept under
`/var/backups/lnmesh/lnd-*` on each Pi. The optional radio bus is not done.

## 1. Full Bitcoin nodes on every Pi (Neutrino stays as an option)

- Install Bitcoin Core on b and c. Leaves have no Internet, so the gateway
  fetches the tarball once and copies it over the mesh.
- Each leaf runs bitcoind on regtest with RPC and ZMQ on loopback and peers
  only with its mesh neighbors.
- LND on every node uses its local bitcoind. `configure-lnd.sh` keeps a
  `neutrino` mode for leaves so the light client can still be deployed.

Done when: `bcli getblockcount` matches on a, b, c and `lncli-mesh getinfo`
on b and c reports synced_to_chain with the bitcoind backend.

Done. Heights 2379 on all three, backend bitcoind on all three.

## 2. Chain traffic routed over a bus a-b-c

- Bitcoin peering forms a bus. a peers with b, b peers with a and c, c peers
  with b. No a-c Bitcoin connection.
- Optional radio bus: drop wlan0 frames between a and c so the mesh itself
  is a bus and batman-adv forwards through b.
- A transaction from c reaches a's mempool through b. A block mined on a
  reaches c through b.

Done when: c opens a channel, the funding transaction appears in a's mempool
with no a-c peer connection, a mines, and c sees the channel active.

Done. c peers only with b, a peers only with b, funding tx a70b65e2 reached
a's mempool, channel active on both ends after 6 blocks, 10,000 sat paid c to b.

## Paper

Replace the PENDING comments in `paper/architecture.tex`,
`paper/design.tex` and `paper/evaluation.tex` for these two items with the
measured results. Everything else in those files stays marked pending.
