# Cardano arm

This arm runs a two-party Hydra Head between the two offline leaves and a
watchtower on the gateway in the form of a mirror node per leaf. Cardano has
no payment channel on layer 1, so this arm uses Hydra Head, the isomorphic
state channel of Cardano and the natural analog of the Perun channel in the
Ethereum arm. Each leaf starts with 100 ADA of funds and deposits its whole
funds address, so the deposits drift with the outcomes of the previous runs.
The payments are 1 ADA, because every output must carry the min-UTxO amount of
about 0.9 ADA. The top-level README describes the testbed and the shared
design, and RESULTS.md holds the measurements.

## What runs where

| Node | Role | Software |
|---|---|---|
| pi1gateway | chain host and mirrors | cardano-node 11.0.1 from the static linux-arm64 release, as a single-pool devnet with the Hydra 2.4.1 devnet genesis, 1 s slots, an active slot coefficient of 0.1, network magic 42 and the Conway era, cardano-cli 11.0.0, `sockfwd.py` publishing the node socket on TCP 3333, and two mirror hydra-nodes with one `hydrapay` observer each |
| pi2 | leaf, pays first | hydra-node 2.4.1, `hydrapay node`, `sockfwd.py` and cardano-cli |
| pi3 | leaf, the victim | the same |

The leaves have no Internet, no DNS, no Docker, no socat and no sudo. The
gateway fetches everything and copies it over the mesh with scp and tar.
hydra-node ships no aarch64 Linux binary in its GitHub releases, so
`01-setup-and-distribute.sh` pulls the linux/arm64 layer of the official
Docker image from ghcr.io (74 MB compressed). `hydra-node.sh` then runs the
nix-built binary through the glibc loader of the image, without Docker and
without root. hydra-node carries its own etcd and extracts it into
`persistence/bin/etcd` at start. The hydra-node of each leaf reaches the
cardano-node of the gateway through a local UNIX socket forwarded to the
gateway by `sockfwd.py`. The gateway needs python3 with venv, jq, curl and
git. The scripts download the cardano-node release, the Hydra devnet
configuration and the hydra-node image.

## How a payment works

A Hydra Head opens on layer 1 with an `Init` transaction and receives funds
through deposit transactions. Each leaf signs its deposit with its funds key.
Inside the head a payment is an ordinary Cardano transaction with zero fee.
hydrapay picks one of its UTxOs from the confirmed snapshot, builds a
transaction with pycardano that pays the peer and returns the change, signs it
with the Ed25519 funds key of the leaf and hands it to its hydra-node. The
hydra-nodes validate the transaction with the Cardano ledger rules and sign
the next snapshot over the Hydra network, which runs on etcd over the mesh, so
no chain contact is needed. A close posts the latest multi-signed snapshot on
layer 1 and waits out the contestation period. Then a fanout transaction
recreates the UTxOs of the head on layer 1. A node that observes a close with
an older snapshot than its own contests automatically, which pushes the
deadline by one contestation period.

## The tower

The Head validator accepts a contest only from a transaction with the
signature of a participant, so no third party can contest for a leaf. Hydra
supports mirror nodes for exactly this case. A mirror is a second hydra-node
with the same Hydra signing key and the same Cardano signing key as its leaf.
It takes part in the Hydra network as a peer, signs snapshots alongside its
leaf and posts Close, Contest and Fanout as the leaf. The gateway runs one
mirror per leaf, with an observer instance of hydrapay next to it for logging
and for the fanout. The mirror receives every snapshot over the network, so
the leaf hands nothing extra to the tower. The mirror holds the Cardano node
key of the leaf, which owns the fuel for fees, and runs without the funds key.
Consequently a dishonest mirror could spend the fuel and post a close or a
contest, but it could not move the funds inside the head. The gateway of this
testbed generated every key and keeps a copy under `keys/` for
`consolidate.sh` between runs. A deployment would generate the funds
keys on the leaves.

A mirror also changes the attack. A rolled-back leaf that can still reach a
majority of the etcd cluster resynchronises before it can close, and a node
that restarts with an empty etcd directory and no peers never posts its close
at all. So the attacker in the cheat test stops its own mirror first, because
an attacker would not keep a mirror that works against it, and restarts from
its stale copy while the victim is offline. Two of the four cluster members
are then down, so the cluster has no quorum and the attacker keeps its stale
snapshot and closes with it.

## Timing rules of Hydra that shape the scripts

hydra-node gives a deposit transaction a validity window of half the deposit
period, capped at 200 s, and the end of that window becomes the creation time
of the deposit. The deposit becomes active one deposit activation after its
creation, and only then does a snapshot carry it and an increment transaction
claim it. The increment transaction gets a validity window of one contestation
period, capped at 200 s, and the deposit validator rejects it when that window
reaches past the deposit deadline minus the deposit period. Thus the slot
length must stay at 1 s, or every deposit waits minutes. Similarly, the
deposit period must cover the creation delay, the activation, a few block
intervals and the contestation period. `02-start-nodes.sh` sets the deposit
period to the contestation period plus 300 s, so a deposit takes about half
the deposit period plus the activation plus a few blocks, which was
196 to 250 s in the runs.

hydra-node also gives its close, contest and fanout transactions a validity
upper bound of one contestation period, capped at 200 s, after the time of the
last block it saw. The Head validator rejects a contest whose upper bound
passes the contestation deadline. The deadline of a close lies one
contestation period after the upper bound of the close transaction itself, so
a participant can contest only during roughly the first contestation period
after the close, although the head stays closed for two. RESULTS.md shows
that boundary with victims that return 30 s and 60 s after the close. The
same bound lets a close or a fanout expire in the mempool after a long block
gap without any error, so hydrapay sends a close again after 90 s.

hydra-node refuses payments once it has seen no block for the unsynced
period. Its default of half the contestation period is shorter than a normal
block gap on this chain when the period is 60 s, so the scripts set 300 s.
With mainnet block gaps and a period of 60 s the expiry above hit about one
transaction in twenty, so the devnet runs with an active slot coefficient of
0.1, one block every 10 s on average.

## hydrapay

One Python program, `hydrapay/hydrapay.py`, on pycardano 0.19.2 and
websocket-client.

* `hydrapay node ...` runs next to a hydra-node. It subscribes to the events
  of the node over a WebSocket and logs them with timestamps, calls the HTTP
  API for deposits and payments, and serves a line-based control port on
  127.0.0.1:7200. Without `-skey` it runs as an observer. The gateway runs
  one observer next to each mirror.
* `hydrapay ctl <cmd>` sends one of the following commands to a node.

| Command | Effect |
|---|---|
| `init` | opens the head on layer 1 |
| `deposit` | deposits the whole funds address into the head |
| `pay <ADA>` | pays the peer inside the head |
| `bal`, `snapshot`, `head` | print the balances, the confirmed snapshot and the head state |
| `close` | closes, waits for the deadline and fans out |
| `closeonly`, `fanout` | run the two halves of `close` separately |
| `recover` | reclaims an expired deposit |
| `info`, `ping` | print the node identity and check liveness |

`deposit` drafts the deposit transaction through `POST /commit` of hydra-node,
signs it with cardano-cli, because the byte-exact re-serialisation matters
there, and submits it through `POST /cardano-transaction`. `pay` submits
through `POST /transaction`, which answers 202 at once, and measures the time
to the `SnapshotConfirmed` event that contains the transaction. `recover`
reclaims an expired deposit with `DELETE /commits/<txid>`, and `deposit` calls
it on its own when a deposit expires. `sockfwd.py` replaces socat with the
standard library.

## Scripts

All scripts run on the gateway from `~/lnmesh-ada`, and `push.sh` in the
repository root puts them there.

* `00-start-devnet.sh [slot] [coeff] [epochSlots]` fetches the cardano-node
  release and the Hydra 2.4.1 devnet configuration, and starts a fresh devnet
  and the socket forwarder.
* `01-setup-and-distribute.sh` creates the keys and funds them from the devnet
  faucet. It sets the ledger parameters of the head with zero fees, a
  maxTxSize of 10250 and the min-UTxO rule kept, publishes the Hydra scripts,
  builds the Python environment and copies everything to the leaves.
  `SKIP_FUND=1` skips the funding.
* `02-start-nodes.sh [pi2|pi3|pi2m|pi3m|mirrors|all]` starts or restarts the
  forwarder, hydra-node and hydrapay on the leaves, and the mirrors with their
  observers on the gateway. `CP`, `DP`, `DA` and `US` set the head parameters
  in seconds, and `TOWER=0` runs without mirrors.
* `consolidate.sh` merges the UTxOs of each funds address into one output on
  layer 1. The experiment scripts call it at their first step.
* `ctl.sh <pi2|pi3|pi2m|pi3m> <cmd>` sends a timestamped control command.
* `lib.sh` holds the shared helpers of the experiment scripts.
* `03-basic.sh [CP]` runs init, the deposits, payments both ways, the close
  and the fanout.
* `04-cheat-test.sh <CP> <online|offline:N> [tower]` runs the stale-snapshot
  attack by pi2 with pi3 online, back N seconds after the close, or back after
  N seconds with the mirror in place.
* `05-latency-and-outage.sh [N_A] [N_B] [N_C] [CP]` measures the payment
  series, the payments with cardano-node frozen, the close and the resource
  use.
* `latency-stats.py <transcript>` prints the latency table of a run of `05`.
* `hydra-node.sh` and `extract-image.py` are the install helpers described
  above.
* `contest-log.py` prints the contest attempts of a hydra-node from its log,
  so the transcript of a cheat test shows why a late contest fails.

The gateway keeps the devnet, the keys, the binaries, the hydra-node image and
the mirror directories under `~/lnmesh-ada/`. A leaf keeps its keys, the image, the Python environment and the persistence
of its hydra-node under the same path.

## Restart

`00-start-devnet.sh` starts from a fresh genesis, so run
`01-setup-and-distribute.sh` again afterwards, which publishes the Hydra
scripts again, and wipe `persistence/` on the leaves and `mirror-*/` on the
gateway. The experiment scripts wipe those directories at their first step.
The devnet faucet key is `devnet/credentials/faucet.sk` from the Hydra
repository. A leaf that misses a deposit deadline keeps its funds in the
deposit output, and `ctl recover` returns them.

## Limitations

* The leaves trust the cardano-node of the gateway for chain data, as in the
  other arms.
* The arm supports one head with two parties, direct peers only and ADA only.
* The hydra-node API and the control port are unauthenticated and bound to
  localhost. Only the Hydra signatures authenticate the Hydra network port on
  the mesh.
* The leaves have no sudo, so the scripts cannot firewall the peer link.
  Therefore the attacker relies on the missing etcd quorum instead of cutting
  its links.
* A deposit takes the whole funds address. After a fanout the funds address
  holds one output per received payment, and the ledger rejected a deposit
  that spent sixteen of them at submission, so every experiment first merges
  each funds address into one output with `consolidate.sh`.
* Block arrivals are random with an average gap of 10 s, so single gaps of a
  minute occur, and every on-chain step of this arm inherits that variance.
