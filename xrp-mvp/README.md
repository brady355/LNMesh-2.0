# XRP Ledger arm

This arm runs native XRP Ledger payment channels between the two offline
leaves and a watchtower on the gateway. The tower redeems for a payee while
the payee is offline. The top-level README describes the testbed and the
shared design, and RESULTS.md holds the measurements.

## What runs where

| Node | Role | Software |
|---|---|---|
| pi1gateway | chain host and tower | `xrpld` 3.2.1 compiled from source on the Pi, in stand-alone mode with a private genesis ledger, `ledger-loop.py` closing a ledger every 4 s, `xrppay tower` and a Python 3.13 environment with xrpl-py 5.1.0 |
| pi2 | leaf, pays first | `xrppay node` with the wallet pi2.json |
| pi3 | leaf, the victim | `xrppay node` with the wallet pi3.json |

The gateway builds everything and copies it to the leaves over the mesh. The
leaves reach the ledger only at the public side of the RPC port of the
gateway, because xrpld accepts admin commands such as `ledger_accept` from
127.0.0.1 only. The gateway needs python3 with venv and an xrpld binary under
`~/bin/xrpld`. `build-xrpld.sh` builds that binary from source with Conan 2,
CMake and Ninja from pip, which took two hours on the Pi 5.

## How a payment works

Payment channels are the native off-ledger primitive of the XRP Ledger. The
payer locks XRP in a channel with `PaymentChannelCreate`. Every payment is a
claim. The payer signs the cumulative amount owed with the key of the channel
and sends the claim to the payee over the mesh. The payee verifies the
signature locally, checks that the amount grows and stays within the funding
of the channel, writes the claim to disk with fsync and acknowledges it. No
ledger contact is needed. Later the payee redeems its highest claim with one
`PaymentChannelClaim` transaction, and the same transaction can close the
channel. A channel is unidirectional, so the basic run opens a second channel
in the other direction for the payments from pi3 to pi2.

There is no stale-state attack on this ledger, because only the payee submits
claims and it only ever wants the newest one. The only move of the payer
against a payee is a scheduled close. A `PaymentChannelClaim` with the close
flag from the payer sets the expiration of the channel to the settle delay
after the current ledger. The payee must redeem before that time, or the payer
takes back everything that is unredeemed.

## The tower

xrpld accepts a claim only from the source or the destination of the channel,
so a tower cannot redeem with its own account. Instead the payee pre-signs the
redemption. After every accepted claim the payee builds the
`PaymentChannelClaim` that pays out the claim and closes the channel, signs it
and hands the signed blob to `xrppay tower` on the gateway. The blob spends a
Ticket of the payee, so the later transactions of the payee never invalidate
it, and the blob carries no expiry. The tower keeps the newest blob per
channel and polls the channel entry every 2 s. As soon as it sees an
expiration on the channel, it submits the blob. The tower holds no key. It can
pay the payee early and close the channel, and it can do nothing else. The
pre-signing runs in a background thread of the payee, so it never delays the
acknowledgement of a claim.

## xrppay

One Python program, `xrppay/xrppay.py`, on xrpl-py 5.1.0.

* `xrppay keygen -out pi2.json -pub pi2.pub` creates an ed25519 wallet and the
  public file for the peer.
* `xrppay fund -rpc URL -to ADDR -xrp N` pays from the genesis account of the
  stand-alone ledger.
* `xrppay node ...` runs the channel node. The node reaches the ledger over
  JSON-RPC to the gateway and its peer over a TCP link on port 6100 with one
  JSON object per line. It keeps its state in a JSON file written with fsync.
  A watcher thread polls the incoming channel every 2 s, and a line-based
  control port listens on 127.0.0.1:7100. With `-tower HOST:PORT` the node
  feeds the tower.
* `xrppay tower ...` runs the tower on the gateway on port 6600.
* `xrppay ctl <cmd>` sends one of the following commands to a node.

| Command | Effect |
|---|---|
| `open <XRP> <settleSeconds>` | creates and funds an outgoing channel |
| `pay <XRP> [force]` | signs the next cumulative claim, and `force` skips the funding check to test the payee |
| `bal`, `onchain`, `ledger` | print the channel state, the account balance and the validated ledger |
| `chan [in\|out]` | prints the ledger entry of a channel |
| `redeem` | redeems the best claim and keeps the channel open |
| `close [in\|out]` | closes the channel. On the payee it redeems the best claim and closes in one transaction, the cooperative path. On the payer it requests the closure, waits out the settle delay and sends the final closing transaction, the unilateral path |
| `forge <XRP>` | tries to redeem a claim with the wrong key, to test the ledger |
| `watch`, `tower` | print the last poll of the watcher and what the tower holds |
| `peerping`, `info`, `ping` | check the peer link and the node |

The watcher of the payee redeems the best claim with close as soon as it sees
the scheduled expiration. `pay ... force` and `forge` exist only to test the
cheating cases.

## Scripts

All scripts run on the gateway from `~/lnmesh-xrp`, and `push.sh` in the
repository root puts them there.

* `build-xrpld.sh` builds xrpld 3.2.1 from source into `~/src/rippled/.build`
  and needs to run once.
* `00-start-ledger.sh [interval]` writes `xrpld.cfg`, wipes and starts the
  stand-alone ledger and starts the ledger loop, 4 s by default.
* `01-setup-and-distribute.sh` builds the Python environment, creates the
  wallets, funds them from genesis and copies the environment, the code and
  the keys to the leaves. `SKIP_FUND=1` skips the funding.
* `02-start-nodes.sh [pi2|pi3|tower|all]` starts or restarts the nodes and the
  tower. `TOWER=0` stops the tower and starts the leaves without it.
* `ctl.sh <pi2|pi3> <cmd>` sends a timestamped control command over ssh.
* `03-basic.sh [XRP] [settle]` opens both channels, pays both ways, tries two
  cheats, redeems a checkpoint and closes cooperatively.
* `04-close-test.sh <settle> <online|offline:N> [tower]` runs the close by the
  payer with the payee online, back N seconds after the close request, or
  back after N seconds with the tower in place.
* `05-latency-and-outage.sh [N_A] [N_C]` measures the payment series, the
  payments with xrpld frozen, the cooperative close and the resource use.
* `latency-stats.py <transcript>` prints the latency table of a run of `05`.

## Restart

`00-start-ledger.sh` starts from a fresh genesis, so run
`01-setup-and-distribute.sh` again afterwards to fund the leaf accounts, and
delete `state.json` on the leaves and `tower.json` on the gateway. The
experiment scripts delete both at their first step. The genesis account is
`rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh` with the well-known secret
`snoPBrXtMeMyMHUVTgbuqAfg1SUTb`. The genesis ledger starts with a base reserve
of 10 XRP and an owner reserve of 2 XRP, so every Ticket costs 2 XRP of
reserve while it exists. xrpld renames its main thread to `xrpld-main`, so
the scripts match it with `pgrep -f bin/xrpld`.

## Limitations

* The leaves trust the gateway RPC for ledger data, as in the other arms.
* The arm supports one channel per direction, direct peers only and XRP only.
* Claims and blobs travel in plain TCP. They are self-authenticating, but the
  peer link, the tower port and the control port are unauthenticated.
* The pre-signed blob carries a fixed fee of 10 drops, the base fee of this
  ledger. A public ledger under load would need a higher fee.
* If an acknowledgement is lost after the payee stored a claim, the counters
  of the payer and the payee diverge, and the payee rejects the next claim as
  stale. A production node would resynchronise on reconnect.
* The claim round trip is dominated by pure Python ed25519 in xrpl-py and two
  fsyncs to the SD cards.
