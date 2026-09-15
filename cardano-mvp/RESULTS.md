# Cardano arm, results of 15 September 2026

All times are UTC. pi1gateway runs cardano-node 11.0.1 as a single-pool devnet
with 1 s slots and an active slot coefficient of 0.1, so blocks arrive every
10 s on average and single gaps of a minute occur. The leaves pi2 and pi3 sit
on batman-adv over ad hoc WiFi without Internet, and every transcript starts
with a failed ping from both leaves to 1.1.1.1. Each leaf runs hydra-node 2.4.1
and hydrapay, and the gateway runs a mirror hydra-node per leaf with a hydrapay
observer next to it. pi2 pays first and attacks, and pi3 is the victim. The
contestation period is 60 s, the deposit period 360 s, the deposit activation
15 s and the unsynced period 300 s. All amounts are ADA on the private devnet.
The raw transcripts are in `results/`. `run-03-basic.txt` holds the basic run,
the fifteen `run-04-*.txt` files hold three repetitions of each dispute
scenario, and `run-05-latency-outage.txt` holds the latency run.

hydrapay measures every latency inside itself around the operation, from the
payment request to the snapshot event that confirms it or across the whole
on-chain sequence, so the numbers exclude ssh. Each leaf deposits its whole
funds address, so the deposits drift with the outcomes of the previous runs,
and `consolidate.sh` merges each funds address into one output before every
run. pi2 received two top-ups from the devnet faucet during the day, because
it pays 5 ADA in every dispute run.

## What the on-chain steps cost on this chain

| Step | Time across the runs |
|---|---|
| init, which opens the head without funds | 0.8 to 43 s, one block |
| deposit, from the draft to the increment in the head | 196 to 250 s |
| close observed after the command | 0.5 to 29 s, one block, and once 102 s after a resend |
| fanout after ReadyToFanout | 7 to 56 s, one block |

The deposit is slow by construction. hydra-node gives the deposit transaction
a validity window of half the deposit period, 180 s here, and the end of that
window is the creation time of the deposit. The deposit becomes active 15 s
later, and only then does a snapshot carry it and an increment transaction
claim it. Thus the deposit period of 360 s, which keeps the increment inside
its validity window, also sets the deposit time at about 200 s.

## Basic run

| Step | Result |
|---|---|
| init | 5960 ms |
| deposit by pi2 of 41.53 ADA | 208.2 s, recorded after 16.2 s and active after 207.2 s |
| deposit by pi3 of 156.68 ADA | 228.3 s, recorded after 10.3 s and active after 215.3 s |
| five payments pi2 to pi3, 1 ADA each | 47, 52, 56, 44 and 63 ms, with 0.7 to 0.9 ms of signing and 16 to 24 ms of HTTP |
| two payments pi3 to pi2 | 53 and 56 ms |
| close by pi2 | observed after 7121 ms, deadline 05:32:48 |
| ReadyToFanout | 119.1 s after the close command |
| fanout finalized | 134.2 s after the close command |
| final split in the head and on layer 1 | 38.53 / 159.68 |

The two mirrors took part in every snapshot, so the snapshot rounds ran with
four members. hydra-node logs a failed increment on every node that lost the
race to post it, which is harmless.

## Dispute scenarios

Every dispute run follows the same script. pi2 copies its hydra-node
persistence right after the deposits, at snapshot 2. Then it pays pi3 five
times, so snapshot 7 holds 5 ADA more for pi3. pi2 restores the copy and
closes the head with what it has. The client of pi2 observes the close at some
block time, and that time is the reference time T of the tables below.
hydra-node gives the close transaction a validity upper bound of one
contestation period after the last block it saw. The contestation deadline
lies one period after that bound, so the deadline sat 90 to 110 s after T in
these runs. Each
scenario ran three times.

### Victim online, no tower

pi2 restarts from its stale copy while pi3 stays up.

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| snapshot in the close of pi2 | 7, the honest one | 7 | 7 |
| close observed after the command | 3.8 s | 1.6 s | 12.1 s |
| fanout by pi3, finalized after its command | 106.3 s | 134.3 s | 112.3 s |
| fanout by pi2 | fails, the head is already final | fails | fails |
| final split | honest, pi3 gains 5 ADA | honest | honest |

The Hydra network layer replays its etcd log to a returning member, so the
rolled-back node was back at snapshot 7 before its close landed, and the close
carried the honest snapshot in all three runs. A cheater therefore needs an
unavailable network. The offline runs provide that, because the victim is down
and the attacker stops its own mirror.

### Victim back 32 s after the close, no tower

The script stops the hydra-node of pi3 before the attack and restarts it 30 s
after the close command returns, which was 31.8 s after T in every run.

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| close observed after the command | 5.7 s | 6.4 s | 19.6 s |
| pi3 restarted | T plus 31.8 s | T plus 31.8 s | T plus 31.8 s |
| pi3 posts a contest with snapshot 7 | 4.0 s after the restart | 4.1 s | 4.0 s |
| the contest lands on chain | 20.6 s after the restart | 7.6 s | 4.6 s |
| contestation deadline | pushed by one period | pushed | pushed |
| fanout by pi3, finalized after its command | 145.3 s | 130.3 s | 134.3 s |
| final split | honest, pi3 gains 5 ADA | honest | honest |

The returning node observed the stale close during its chain sync and posted
its contest 4 s after the restart in every run. The contest waited for the
next block, so it landed 5 to 21 s after the restart.

### Victim back 62 s after the close, no tower

The script restarts pi3 60 s after the close command returns, which was 61.8 s
after T in every run.

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| close observed after the command | 14.1 s | 4.9 s | 13.9 s |
| contestation deadline | T plus 106 s | T plus 109 s | T plus 90 s |
| pi3 restarted | T plus 61.8 s | T plus 61.8 s | T plus 61.8 s |
| pi3 posts a contest with snapshot 7 | 4.1 s after the restart | 3.9 s | 3.9 s |
| outcome of the contest | lands 21.6 s after the restart and pushes the deadline | rejected with the validator errors H30 and PT5 | rejected with H30 and PT5 |
| fanout, finalized after its command | by pi3 with snapshot 7, 109.2 s | by pi2 with snapshot 2, 127.3 s | by pi2 with snapshot 2, 99.4 s |
| final split | honest, pi3 gains 5 ADA | stale, pi3 loses the 5 ADA of payments | stale |

This scenario sits on the boundary. hydra-node gives a contest a validity
upper bound of one contestation period after the last block its node has
seen, and the Head validator rejects a contest whose upper bound passes the
contestation deadline, which is error H30. With a victim back at 62 s that
bound lands past the deadline unless the last block before the contest is old
enough, so the outcome depends on the random block gap at that moment. The
contest won in run 1 and lost in runs 2 and 3. Consequently the safe window
for a returning victim is shorter than one contestation period after the
close, although the head stays closed for two.

### Victim back 202 s after the close, no tower

The script restarts pi3 200 s after the close command returns, which was
202.1 s after T in every run.

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| close observed after the command | 5.9 s | 4.5 s | 28.9 s |
| fanout by pi2 with snapshot 2, finalized after its command | 120.3 s | 131.3 s | 79.4 s |
| pi3 restarted | T plus 202.1 s, the head is already Idle | same | same |
| pi3 posts a contest with snapshot 7 | 4.1 s after the restart, rejected with H30 and PT5 | 4.0 s, rejected | 4.1 s, rejected |
| final split | stale, pi3 loses the 5 ADA of payments | stale | stale |

pi2 fanned out the stale snapshot about two minutes after its close, so the
victim returned to a settled head and its contest had nothing left to contest.

### Victim back 202 s after the close, with the mirror

Same as the previous scenario, but the mirror of pi3 runs on the gateway. The
attacker stops its own mirror first and restarts from its stale copy while pi3
is offline, so the four-member etcd cluster has no quorum and cannot
resynchronise it.

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| close observed after the command | 10.0 s | 102.0 s, after a resend | 5.3 s |
| the mirror of pi3 observes the close | T plus 1.4 s | T plus 1.4 s | T plus 1.4 s |
| the mirror contests with snapshot 7 | T plus 2.4 s | T plus 8.4 s | T plus 22.4 s |
| contestation deadline | pushed by one period | pushed | pushed |
| pi3 restarted | T plus 202 s, after the pushed deadline | same | same |
| the own contest of pi3 | 3.9 s after the restart, rejected with H30 and PT5 | 4.1 s, rejected | 4.2 s, rejected |
| fanout by the mirror, finalized after its command | 12.0 s | 6.9 s | 7.0 s |
| final split | honest, pi3 gains 5 ADA | honest | honest |

The mirror observed the close within 1.4 s in every run and contested in the
next block, 1 to 21 s later. The victim returned after both deadlines to a
head that was already settled in its favour, and the mirror fanned out on its
behalf. In run 2 the first close transaction of the attacker expired in the
mempool during a long block gap, so hydrapay sent it again after 90 s, and the
whole run took 102 s longer.

## Latency and chain outage

| Series | n | errors | min | median | mean | p95 | max (ms) |
|---|---|---|---|---|---|---|---|
| A, pi2 to pi3 with the chain up | 50 | 0 | 39 | 58 | 61.9 | 82 | 114 |
| B, pi3 to pi2 with the chain up | 20 | 0 | 52 | 70 | 73.4 | 112 | 112 |
| C, pi2 to pi3 with cardano-node frozen by SIGSTOP | 10 | 0 | 68 | 78 | 80.0 | 97 | 97 |

Signing took 0.7 to 1.0 ms and the HTTP round trip to the local hydra-node 13
to 37 ms, and the rest is the snapshot round over the mesh with four members.
The chain was frozen for 55 s and the payments continued unchanged, and the
node never reported itself out of sync. After the unfreeze the close by pi3
was observed after 774 ms, ReadyToFanout came 129.8 s after the close command
and the fanout finalized at 185.8 s with 82 UTxOs to distribute. Layer 1 then
held 48.18 and 247.49 ADA, which matches the head.

## Resource use at the end of the latency run

| Process | RSS | CPU |
|---|---|---|
| hydra-node on pi2 / pi3 | 169 / 170 MB | 5.8 / 6.9 percent |
| etcd, spawned by hydra-node, on pi2 / pi3 | 53 / 46 MB | 1.1 / 0.7 percent |
| hydrapay per leaf | 83 MB | 0.2 percent |
| sockfwd per leaf | 20 MB | |
| mirror hydra-node on the gateway, per leaf | 169 / 164 MB | 5.9 / 5.9 percent |
| mirror etcd on the gateway, per leaf | 47 / 45 MB | 0.9 / 0.9 percent |
| observer on the gateway, per leaf | 80 MB | 0.2 percent |
| cardano-node on the gateway | 202 MB | 0.3 percent |

Sizes: Docker layer 74 MB, extracted image 276 MB, Python environment 72 MB,
cardano-node binary 146 MB and cardano-cli 132 MB. CPU is the average over the
lifetime of the process.

## What the arm shows

A victim must contest within roughly one contestation period after the close,
not two, because hydra-node bounds the validity of the contest transaction by
the contestation period after the last block it saw. A victim back at 32 s won
three times, a victim back at 62 s won once and lost twice, and a victim back
at 202 s always lost. The mirror closes that gap with the own keys of the leaf,
because the Head validator accepts a contest only from a participant. It
contested 2 to 22 s after the close in the three runs, each time in the block
after it saw the close. The mirror also joins every snapshot round, so it
needs no extra message from the leaf, and it costs the gateway about 290 MB of
memory per leaf.
