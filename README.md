# OffPay

OffPay runs offline payments over a wireless mesh network and protects them
with a watchtower on the gateway of the mesh. This repository holds three
minimum viable implementations, one each for Ethereum, the XRP Ledger and
Cardano, together with the experiment scripts and the transcripts of every
measured run. Nothing here is production code. Each implementation is the
smallest one that lets a paper measure the protocol.

## Background

[LNMesh](https://ieeexplore.ieee.org/document/10195433) showed that the
members of a community wireless mesh network can pay each other with the
Lightning Network while they have no Internet connection. A payment inside a
channel touches no chain, so two offline neighbours can keep paying as long as
the mesh connects them. However, that setup leaves the channel unprotected. A
channel partner that regains Internet access before the other can settle an
old channel state on the chain, and the victim cannot answer while it is
offline. This repository closes that gap for three further blockchains. One
Raspberry Pi in the mesh, the gateway, keeps the only chain connection. The
offline members reach the chain only through the gateway, and the gateway runs
a watchtower on their behalf. The Lightning arm of the same testbed is
documented separately.

## The testbed

Three Raspberry Pi 5 boards form the mesh with batman-adv over ad hoc WiFi.
The gateway owns the only Internet connection, so it runs the chain process
and the watchtower of every arm. The two leaves have no Internet, no DNS and
no sudo, and every experiment transcript begins with a failed ping from both
leaves to 1.1.1.1.

| Node | Mesh address | Role |
|---|---|---|
| pi1gateway | 10.10.0.1 | chain process, relay and watchtower |
| pi2 | 10.10.0.2 | leaf, pays first in every experiment |
| pi3 | 10.10.0.3 | leaf, the victim in every attack |

The chains run as private networks on the gateway, in the same way that
regtest ran on the gateway in the Lightning work. Their block intervals follow
the public networks, so every on-chain step takes realistic time. anvil and
the XRP Ledger loop produce blocks on a fixed schedule. The Cardano devnet
draws its block times at random like mainnet, but at twice the mainnet rate.
hydra-node bounds its dispute transactions by the contestation period, and
mainnet block gaps let those transactions expire when that period is 60 s.

| Arm | Chain process on the gateway | Block interval |
|---|---|---|
| Ethereum | anvil 1.8.1 | 12 s |
| XRP Ledger | xrpld 3.2.1 in stand-alone mode, one ledger per tick of `ledger-loop.py` | 4 s |
| Cardano | cardano-node 11.0.1 as a single-pool devnet with 1 s slots and an active slot coefficient of 0.1 | 10 s on average |

## Design

Three elements repeat in every arm.

**The relay.** A leaf never talks to the public network. It signs its
transactions locally, submits them through the gateway and reads the chain
state through the gateway. The Ethereum leaves use the websocket RPC of anvil,
the XRP leaves use the public JSON-RPC port of xrpld, and the Cardano leaves
use a node socket forwarded over the mesh by `sockfwd.py`. The leaves do not
verify blocks themselves, so they trust the gateway for chain data.
Consequently the gateway can delay or hide chain data from a leaf. However, it
holds no key that spends the funds of a leaf.

**The channel.** Payments travel peer to peer over the mesh and touch no
chain, so they keep working while the chain process of the gateway is frozen.
Every arm measures that. The dispute rules differ per chain, and so does the
attack.

| Arm | Off-chain construction | Payment | Attack | Honest response |
|---|---|---|---|---|
| Ethereum | Perun ledger channel | signed state update | the payer registers an old state | register the newest state within the challenge duration |
| XRP Ledger | native payment channel | signed cumulative claim | the payer schedules the close while claims are unredeemed | redeem the newest claim within the settle delay |
| Cardano | Hydra Head | transaction in a multi-signed snapshot | the payer closes with an old snapshot | contest with the newest snapshot within the contestation period |

Without a tower the honest response must come from the victim itself, so the
victim loses when it returns after the window. The baseline experiments show
that in every arm.

**The watchtower.** Each chain restricts differently who may post the honest
response, so each arm has a different kind of tower.

| Arm | What the tower holds | Who signs the response | Can the tower spend for the leaf |
|---|---|---|---|
| Ethereum | the newest state with both signatures | the tower with its own account, because the Adjudicator accepts `register` from any account | no |
| XRP Ledger | a pre-signed claim-and-close transaction of the payee over a Ticket | the payee in advance, because xrpld rejects a claim from any account other than the source or the destination | no |
| Cardano | the Hydra key and the Cardano node key of the party, inside a mirror hydra-node | the mirror as the party itself, because the Head validator accepts a contest only from a participant | only the fuel, never the funds in the head |

The Ethereum tower is a third party in the sense of the Lightning watchtowers,
and the XRP tower resembles a Lightning tower with pre-signed justice
transactions. The Cardano tower is a mirror node, which Hydra documents as its
high availability setup, so it is a hot replica of the party rather than a
third party. It cannot move the funds inside the head, because the funds key
stays on the leaf. However, it can close or stall the head at will, and it can
spend the fuel. Thus the three arms span the range from a keyless tower to a
full replica of the party.

## Repository layout

| Path | Content |
|---|---|
| `ethereum-mvp/` | the Ethereum arm with the `perunpay` node and tower in Go |
| `xrp-mvp/` | the XRP Ledger arm with the `xrppay` node and tower in Python |
| `cardano-mvp/` | the Cardano arm with the `hydrapay` client in Python and the mirror setup |
| `common/latency-stats.py` | turns the transcript of a latency run into a table |
| `testbed.env` | the shared testbed definition, sourced by every script |
| `push.sh` | copies the scripts and sources from the laptop to the gateway |
| `run.sh` | runs one experiment script on the gateway and records its transcript |

Each arm holds a `README.md` with its design, a `RESULTS.md` with its
measurements, a `scripts/` directory and a `results/` directory with the
transcripts.

## Running an experiment

Every script runs on the gateway. The laptop only pushes files and records
transcripts. The gateway reaches the leaves over ssh with keys, and the laptop
reaches the gateway under the ssh alias `pi1gateway`, or under the host in
the variable `GW_HOST`.

1. Set `SSH_USER` and the mesh addresses in `testbed.env`.
2. Run `./push.sh all`. It copies everything to `~/lnmesh-eth`, `~/lnmesh-xrp`
   and `~/lnmesh-ada` on the gateway.
3. On the gateway, run the `00` script of an arm to start its chain and the
   `01` script to fund the leaves and distribute the software. The README of
   each arm lists the prerequisites of these two steps.
4. Run an experiment from the laptop, for example
   `./run.sh eth run-03-basic 03-basic.sh 60`. The transcript lands in the
   `results/` directory of the arm.
5. Run `common/latency-stats.py <transcript>` on the transcript of a latency
   run to print the latency table.

Every arm runs the same three experiments.

| Script | Experiment |
|---|---|
| `03` | the basic run, which opens a channel, pays both ways and closes |
| `04` | the dispute, in which the payer attacks while the victim is online, back inside the window or back after the window, with and without the tower |
| `05` | the latency series, then payments while the chain process is frozen with SIGSTOP, then the resource use of every process |

## Results

The `RESULTS.md` of each arm reports the measurements, and the `results/`
directories hold the raw transcripts. All runs come from the same three Pis on
15 September 2026, with a dispute window of 60 s and three repetitions of every
dispute scenario.

| Metric | Ethereum, Perun | XRP Ledger, payment channels | Cardano, Hydra Head |
|---|---|---|---|
| one payment over the mesh, median | 6 ms | 42 ms | 58 ms |
| payments while the chain process was frozen | 10 of 10 | 10 of 10 | 10 of 10 |
| funding a channel or a head | 1 to 12 s | 1 to 4 s | one block to open, then 196 to 250 s per deposit |
| cooperative close | 22 s, plus 12 s for the peer | 1 to 3 s | none, every close waits out the period |
| unilateral close, from the command to the settled state | 107 s | 63 s, the settle delay plus one ledger | 134 s |
| victim online | refutes in the next block | redeems in the next ledger, 4 s | the node of the attacker resynchronises and closes honestly |
| victim back inside the window, no tower | wins, refutes 4 s after its restart | wins, redeems 6 to 7 s after its restart | wins at 32 s, and wins once in three runs at 62 s |
| victim back after the window, no tower | loses its whole deposit | loses the unredeemed claims | loses the payments it received |
| tower reaction | refutes in the block after the registration, 12 s | submits within 1.3 s of the close request, validated in the next ledger | contests in the block after the close, 2 to 22 s |
| victim back after the window, with tower | paid | paid | paid |
| what the tower holds | the newest signed state | a pre-signed claim and close over a Ticket | the Hydra key and the node key of the leaf |
| tower memory on the gateway | 18 MB | 54 MB | about 290 MB per leaf |
| leaf footprint | 23 MB | 48 to 65 MB | hydra-node 170 MB, etcd 46 to 53 MB, hydrapay 83 MB |


## License

MIT, see `LICENSE`.
