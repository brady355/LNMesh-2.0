# Ethereum arm

This arm runs Perun payment channels between the two offline leaves and a
watchtower on the gateway. The tower refutes a stale channel state for a leaf
while the leaf is offline. The top-level README describes the testbed and the
shared design, and RESULTS.md holds the measurements.

## What runs where

| Node | Role | Software |
|---|---|---|
| pi1gateway | chain host, build host and tower | anvil 1.8.1 with chain id 1337 and 12 s blocks, Go 1.27, the `perunpay` sources and `perunpay tower` |
| pi2 | leaf, pays first | `perunpay node` with anvil account 1 |
| pi3 | leaf, the victim | `perunpay node` with anvil account 2 |

The gateway compiles perunpay and copies the binary to the leaves over the
mesh, so the leaves compile nothing. The gateway deploys the Perun contracts,
the Adjudicator and the ETH asset holder, once with anvil account 0. The tower
pays its gas from anvil account 3. The gateway needs Go under `~/sdk/go` and
Foundry under `~/.foundry/bin`, because the scripts use `anvil` and `cast`.

## How a payment works

A Perun ledger channel locks the deposits of both parties in the asset holder
contract. A payment is a state update that moves balance from the payer to the
payee. Both parties sign the update over the mesh, so no chain contact is
needed. A cooperative close signs a final state, and the channel concludes on
chain at once. A unilateral close registers the newest state on the
Adjudicator, which starts the challenge duration. When the duration has
passed, the channel concludes with the registered state. A party that
registers an older state cheats. However, the Adjudicator accepts a `register`
call with a newer version until the timeout, and that call is the refutation.

## The tower

The Adjudicator checks the signatures of both participants on a state and
places no condition on the sender of a `register` call. Consequently any
account with the newest signed state can refute. `perunpay tower` runs on the
gateway with its own funded account and the local watcher of go-perun. A leaf
with `-tower` keeps its own local watcher and also forwards every channel
registration and every signed state to the tower. The forwarding runs in a
background queue in order, so a payment never waits for the tower, and the
queue retries while the tower is unreachable. The tower feeds the states to
its watcher. The watcher subscribes to the Adjudicator, so it registers the
newest state as soon as it observes a registration with an older version. The
tower can start a dispute and can refute one, but it can do nothing else,
because a withdrawal needs the signature of the participant.

## perunpay

One Go program on go-perun v0.15.0 and perun-eth-backend v0.6.0.

* `perunpay deploy` deploys the contracts and writes `contracts.json`.
* `perunpay keygen -name pi2` creates the RSA wire identity of a node and the
  public file for its peer.
* `perunpay node ...` runs a channel client. It uses a TCP wire over the mesh,
  chain access through the websocket RPC of the gateway, LevelDB persistence
  with restore, the dispute watcher and a line-based control port on
  127.0.0.1:7000. The flag `-tower HOST:PORT` adds the tower feed.
* `perunpay tower ...` runs the tower on the gateway on port 6500.
* `perunpay ctl <cmd>` sends one of the following commands to a node.

| Command | Effect |
|---|---|
| `open <myETH> <peerETH> <challengeSeconds>` | proposes and funds a channel |
| `pay <ETH>` | signs a state update that pays the peer |
| `bal`, `onchain` | print the latest channel state and the on-chain balance |
| `close` | closes cooperatively with a final state |
| `forceclose` | closes unilaterally and waits out the challenge |
| `withdraw` | withdraws after the peer concluded |
| `info`, `ping` | print the node identity and check liveness |

The node accepts any two-party ledger channel proposal and any update that
does not lower its own balance.

## Scripts

All scripts run on the gateway from `~/lnmesh-eth`, and `push.sh` in the
repository root puts them there.

* `00-start-chain.sh [blockSeconds]` starts a fresh anvil chain with 12 s
  blocks by default.
* `01-deploy-and-distribute.sh` builds perunpay, deploys the contracts,
  creates the wire identities and copies the binary and the keys to the
  leaves.
* `02-start-nodes.sh [pi2|pi3|tower|all]` starts or restarts the nodes and the
  tower. `TOWER=0` stops the tower and starts the leaves without it.
* `ctl.sh <pi2|pi3> <cmd>` sends a timestamped control command over ssh.
* `03-basic.sh [challenge]` opens a channel, pays both ways and closes it
  cooperatively, then opens again and closes unilaterally.
* `04-cheat-test.sh <challenge> <online|offline:N> [tower]` runs the
  stale-state attack with the victim online, back N seconds after the
  registration, or back after N seconds with the tower in place.
* `05-latency-and-outage.sh [N_A] [N_B] [N_C]` measures the payment series,
  the payments with anvil frozen, the cooperative close and the resource use.
* `latency-stats.py <transcript>` prints the latency table of a run of `05`.

## Restart

anvil keeps its chain in memory, so `00-start-chain.sh` wipes the contracts
and the balances. Run `01-deploy-and-distribute.sh` again afterwards. The
experiment scripts wipe the channel databases of the leaves at their first
step.

## Limitations

* The leaves trust the gateway RPC for chain data, as in the other arms.
* The arm supports one asset, one peer per node and direct channels only.
* A cheating node loses access to its own share after a failed stale
  settlement, because go-perun keeps only the latest state and the node
  destroyed it. The outcome of the honest party does not change.
* When the victim and the tower are both online, both refute, and the second
  transaction reverts. The loser of that race pays one failed transaction and
  nothing else.
* The tower port and the control port are unauthenticated. The control port
  binds to localhost only.
* The adjudicator subscription of go-perun on a freshly restarted node
  delivered the registration event up to 60 s after the block. The long-lived
  subscription of the tower delivered it with the next block. Therefore the
  cheat test reads the dispute from the Adjudicator contract with `cast` and
  counts the absence of the victim from the block time of the registration.
