# Ethereum arm, results of 15 September 2026

All times are UTC. pi1gateway runs anvil 1.8.1 with one block every 12 s. The
leaves pi2 and pi3 sit on batman-adv over ad hoc WiFi without Internet, and
every transcript starts with a failed ping from both leaves to 1.1.1.1. pi2
pays first and attacks, and pi3 is the victim. All amounts are test ETH on the
private chain. The challenge duration is 60 s, and the tower pays its gas from
anvil account 3. The raw transcripts are in `results/`. `run-03-basic.txt`
holds the basic run, the twelve `run-04-*.txt` files hold three repetitions of
each dispute scenario, and `run-05-latency-outage.txt` holds the latency run.

The node measures every latency inside itself around the operation, so the
numbers exclude ssh. A payment latency is the round trip of the Perun update
over the mesh, and an on-chain latency covers the whole sequence from the
command to the settled state. The block times of the dispute events come from
the `ChannelUpdate` events of the Adjudicator contract, read from anvil with
`cast logs` after the runs.

## Basic run

| Step | Result |
|---|---|
| open a channel with 1 ETH per side and a challenge duration of 60 s | 1173 ms, both deposits in one block |
| five payments pi2 to pi3 and two payments pi3 to pi2, 0.01 ETH each | 4 to 7 ms each, versions 1 to 7 |
| cooperative close by pi2, which signs the final update, concludes and withdraws | 22171 ms |
| withdrawal by pi3 | 12075 ms |
| final split | 0.97 / 1.03 |
| on-chain change pi2 / pi3, gas included | minus 0.0302 / plus 0.0299 |
| open again and pay twice | 12140 ms, then 8 and 7 ms |
| unilateral close by pi2, which registers, waits 60 s, concludes and withdraws | 106708 ms |
| withdrawal by pi3 | 12069 ms |
| on-chain change pi2 / pi3 | minus 0.0203 / plus 0.0199 |

An open takes one or two blocks, depending on where the command falls inside
the 12 s block interval. The tower ran alongside, acknowledged every state
within 3 to 9 ms and stopped watching each channel when the leaves closed it.

## Dispute scenarios

Every dispute run follows the same script. pi2 copies its channel database
right after the open at version 0, when both parties hold 1 ETH. Then it pays
pi3 five times, so version 5 reads 0.95 / 1.05. pi2 restores the copy and
force-closes with version 0. The stale registration landed 7 to 9 s after the
command in every run, and its block time is the reference time T of the tables
below. The challenge window of 60 s runs from T. Each scenario ran three times.

### Victim online, no tower

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| stale registration, T | 05:34:18 | 05:46:30 | 05:58:42 |
| pi3 registers version 5 | T plus 12 s | T plus 12 s | T plus 12 s |
| version 5 concluded | T plus 96 s | T plus 96 s | T plus 96 s |
| force close of pi3 returns | 107.6 s | 105.9 s | 105.9 s |
| force close of pi2 fails | after 104.0 s | after 104.3 s | after 104.3 s |
| on-chain change pi2 / pi3 | minus 1.0002 / plus 0.0497 | minus 1.0002 / plus 0.0497 | minus 1.0002 / plus 0.0497 |

pi3 answered in the block after the registration in all three runs. Its
settlement starts with a registration of the newest state, and its local
watcher reacts to the same event, so both race for the same refutation and the
first of them lands. The force close of pi2 fails, because its conclude call
carries version 0 while the Adjudicator holds version 5. pi2 also loses access
to its own 0.95 ETH, because go-perun keeps only the latest state and pi2
destroyed it. Consequently pi2 lost its whole deposit, and pi3 received
1.05 ETH minus its deposit and its gas.

### Victim back inside the window, no tower

The script stops pi3 before the attack and restarts it 20 s after T.

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| stale registration, T | 05:36:54 | 05:49:06 | 06:01:18 |
| pi3 restarted | T plus 20 s | T plus 20 s | T plus 20 s |
| pi3 registers version 5 | T plus 24 s | T plus 24 s | T plus 24 s |
| version 5 concluded | T plus 84 s | T plus 84 s | T plus 84 s |
| force close of pi3 returns | 66.9 s | 67.0 s | 66.9 s |
| force close of pi2 fails | after 103.0 s | after 103.2 s | after 103.1 s |
| on-chain change pi2 / pi3 | minus 1.0002 / plus 0.0497 | minus 1.0002 / plus 0.0497 | minus 1.0002 / plus 0.0497 |

The eth backend of go-perun replays the recent adjudicator events when a node
subscribes. Consequently the returning victim saw the missed registration and
refuted it in the next block, 4 s after its restart and before the script even
asked it to settle. Thus a victim that returns inside the window loses nothing.

### Victim back after the window, no tower

The script restarts pi3 120 s after T, which is 60 s after the timeout.

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| stale registration, T | 05:39:18 | 05:51:30 | 06:03:42 |
| version 0 concluded | T plus 84 s | T plus 84 s | T plus 84 s |
| force close of pi2 returns with version 0 | 103.1 s | 103.0 s | 103.1 s |
| pi3 restarted | T plus 121 s | T plus 121 s | T plus 121 s |
| force close of pi3 fails | after 14.6 s | after 14.6 s | after 14.6 s |
| on-chain change pi2 / pi3 | minus 0.0003 / minus 1.0002 | minus 0.0003 / minus 1.0002 | minus 0.0003 / minus 1.0002 |

Without a tower the stale state stands. pi2 concluded version 0 two blocks
after the timeout and withdrew its full deposit, although it had paid 0.05 ETH
for service. pi3 returned to a concluded channel, so its own registration
failed with a wrong version, and it lost its whole deposit and the payments.

### Victim back after the window, with the tower

Same as the previous scenario, but both leaves feed the tower, and the tower
holds version 5 when pi3 goes offline.

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| stale registration, T | 05:42:30 | 05:54:42 | 06:06:54 |
| the tower registers version 5 | T plus 12 s | T plus 12 s | T plus 12 s |
| pi3 restarted | T plus 120 s | T plus 120 s | T plus 121 s |
| version 5 concluded | T plus 180 s | T plus 180 s | T plus 180 s |
| force close of pi3 returns | 63.2 s | 62.8 s | 62.7 s |
| force close of pi2 fails | after 186.5 s | after 187.1 s | after 186.9 s |
| on-chain change pi2 / pi3 | minus 1.0002 / plus 0.0497 | minus 1.0002 / plus 0.0497 | minus 1.0002 / plus 0.0497 |

The tower refuted in the block after the registration in all three runs. Its
subscription delivered the stale registration and its own refutation together
12 s after T, so the tower needed one block to answer. The victim returned a
minute after the window to a channel already secured by the tower, and
its settlement concluded version 5 and withdrew 1.05 ETH.

## Latency and chain outage

| Series | n | errors | min | median | mean | p95 | max (ms) |
|---|---|---|---|---|---|---|---|
| A, pi2 to pi3 with the chain up | 50 | 0 | 3 | 6 | 6.9 | 12 | 15 |
| B, pi3 to pi2 with the chain up | 20 | 0 | 3 | 7 | 7.0 | 11 | 11 |
| C, pi2 to pi3 with anvil frozen by SIGSTOP | 10 | 0 | 6 | 8 | 7.7 | 10 | 10 |

The chain RPC stopped answering for the whole of series C, and the payments
continued unchanged. Both leaves fed the tower during the run, and the tower
acknowledged each state within a few milliseconds, 4 and 9 ms for the last two
updates. After SIGCONT the cooperative close took 14164 ms on pi2 and 12125 ms
on pi3, and the final split was 0.96 / 1.04.

## Resource use at the end of the latency run

| Process | RSS | CPU |
|---|---|---|
| perunpay node on pi2 | 23 MB | 0.2 percent |
| perunpay node on pi3 | 23 MB | 0.2 percent |
| perunpay tower on the gateway | 18 MB | 0.0 percent |
| anvil on the gateway | 211 MB | 0.0 percent |

The binary is 16.9 MB, and CPU is the average over the lifetime of the
process. anvil keeps its whole chain in memory, so its footprint grows with
the number of blocks, and it had run for 29 hours with a block every 12 s when
the run ended.

## What the arm shows

The tower of this arm is a true third party. It holds nothing but signed
states, it signs the refutation with its own account, and it answered in the
block after every stale registration. A victim inside the window defends
itself in the same way, whereas a victim after the window loses its whole
deposit without the tower.

