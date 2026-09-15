# XRP Ledger arm, results of 15 September 2026

All times are UTC. pi1gateway runs xrpld 3.2.1 in stand-alone mode with a
private genesis ledger and closes one ledger every 4 s. The leaves pi2 and pi3
sit on batman-adv over ad hoc WiFi without Internet, and every transcript
starts with a failed ping from both leaves to 1.1.1.1. pi2 pays and pi3
receives on the channel under test. All amounts are XRP on the private ledger,
and the transaction fee is 10 drops. The raw transcripts are in `results/`.
`run-03-basic.txt` holds the basic run, the twelve `run-04-*.txt` files hold
three repetitions of each dispute scenario, and `run-05-latency-outage.txt`
holds the latency run.

The node measures every latency inside itself around the operation, so the
numbers exclude ssh. A payment latency is the claim round trip over the mesh,
and an on-chain latency covers the sequence from the signing of a transaction
to its validated ledger.

## Basic run

| Step | Result |
|---|---|
| open a channel pi2 to pi3 with 1 XRP and a settle delay of 60 s | 2200 ms, and pi3 verified the channel on the ledger |
| five payments of 0.01 XRP | 36 to 41 ms each, signing 6.4 ms, verification 11 to 12 ms |
| pi2 signs a claim of 5.05 XRP against the 1 XRP channel | pi3 rejects it offline in 16 ms |
| pi3 forges a claim of 0.5 XRP with its own key | xrpld rejects it as malformed (temBAD_SIGNER) |
| checkpoint redeem by pi3 of 0.05 XRP, the channel stays open | 2191 ms |
| open a channel pi3 to pi2 with 1 XRP | 3248 ms |
| two payments each way | 35 and 33 ms from pi3, 37 and 37 ms from pi2 |
| cooperative close of both channels by the payees | 1144 ms and 3257 ms |
| on-chain change pi2 / pi3 | minus 0.05003 / plus 0.04996 |

The tower side ran alongside. pi3 reserved its Ticket in 3268 ms after the
first claim. Every later claim reached the tower as a pre-signed blob of
304 bytes within 34 to 66 ms of the acknowledgement, and the signing took 9 to
38 ms of that. The tower held the newest blob of both channels and never had to
submit one, because both channels closed cooperatively.

## Dispute scenarios

Every dispute run follows the same script. pi2 opens a channel with 1 XRP and
a settle delay of 60 s, pays pi3 five times and then requests the close while
the 0.05 XRP of claims are unredeemed. The close request sets the expiration
of the channel to the settle delay after the close time of the parent ledger,
so pi3 must redeem before that time. The validated ledger of the close request
is the reference time T of the tables below. Each scenario ran three times.

### Payee online, no tower

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| close request validated, T | 06:10:34.7, ledger 873 | 06:17:38.8, ledger 979 | 06:24:51.1, ledger 1087 |
| the watcher of pi3 sees the expiration | T minus 0.2 s | T minus 0.2 s | T plus 0.7 s |
| pi3 redeems 0.05 XRP and closes, validated | T plus 4.2 s, ledger 874 | T plus 4.2 s, ledger 980 | T plus 4.2 s, ledger 1088 |
| close of pi2 returns, channel gone | 8.5 s after its request | 5.3 s | 5.4 s |
| on-chain change pi2 / pi3 | minus 0.05002 / plus 0.04999 | minus 0.05002 / plus 0.04999 | minus 0.05002 / plus 0.04999 |

The watcher polls the validated ledger every 2 s, so it saw the expiration
within a poll interval of the request and redeemed in the next ledger.

### Payee back inside the window, no tower

The script stops pi3 before the close request and restarts it 30 s after the
request command, which was 26 s after T in every run.

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| close request validated, T | 06:11:14.8, ledger 883 | 06:18:23.1, ledger 990 | 06:25:35.3, ledger 1098 |
| pi3 restarted | T plus 26 s | T plus 26 s | T plus 26 s |
| the watcher of pi3 sees the expiration | 3.5 s after the restart | 3.4 s | 3.4 s |
| pi3 redeems and closes, validated | 6.8 s after the restart, ledger 891 | 6.8 s, ledger 998 | 5.7 s, ledger 1106 |
| close of pi2 returns, channel gone | 36.4 s after its request | 37.3 s | 37.2 s |
| on-chain change pi2 / pi3 | minus 0.05002 / plus 0.04999 | minus 0.05002 / plus 0.04999 | minus 0.05002 / plus 0.04999 |

### Payee back after the window, no tower

The script restarts pi3 120 s after the request command, about a minute after
the expiration.

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| close request validated, T | 06:12:22.8, ledger 900 | 06:19:31.0, ledger 1007 | 06:26:42.9, ledger 1115 |
| pi2 finalizes the close after the expiration | 63.5 s after its request | 63.8 s | 63.1 s |
| pi3 restarted | T plus 116 s | T plus 116 s | T plus 116 s |
| the watcher of pi3 | channel gone, 0.05 XRP unredeemed | same | same |
| redeem by pi3 | fails with tecNO_TARGET | same | same |
| on-chain change pi2 / pi3 | minus 0.00003 / minus 0.00001 | minus 0.00003 / minus 0.00001 | minus 0.00003 / minus 0.00001 |

pi2 paid three fees and recovered its whole deposit after receiving 0.05 XRP
of service. pi3 paid the fee of the failed redeem and lost the 0.05 XRP it was
owed.

### Payee back after the window, with the tower

Same as the previous scenario, but pi3 hands its newest pre-signed claim to
the tower after every payment, so the tower holds the fifth claim when pi3
goes offline.

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| close request validated, T | 06:15:03.0, ledger 940 | 06:22:15.4, ledger 1048 | 06:29:27.1, ledger 1156 |
| the tower sees the expiration and submits the blob | T minus 0.3 s, answered tesSUCCESS in 29 ms | T plus 1.1 s, 31 ms | T plus 1.3 s, 24 ms |
| the blob validated | T plus 3.8 s, ledger 941 | T plus 3.2 s, ledger 1049 | T plus 4.4 s, ledger 1157 |
| close of pi2 returns, channel gone | 7.4 s after its request | 7.5 s | 7.4 s |
| pi3 restarted | T plus 117 s | T plus 116 s | T plus 117 s |
| the watcher of pi3 | learns from the tower that the tower redeemed 0.05 XRP | same | same |
| on-chain change pi2 / pi3 | minus 0.05002 / plus 0.04998 | minus 0.05002 / plus 0.04998 | minus 0.05002 / plus 0.04998 |

The tower answered within one ledger of the close request in all three runs,
so the close of the payer closed the channel with the payee paid. The payee
had nothing left to do when it returned two minutes later, and it paid one
extra fee of 10 drops for the Ticket.

## Latency and chain outage

| Series | n | errors | min | median | mean | p95 | max (ms) |
|---|---|---|---|---|---|---|---|
| A, pi2 to pi3 with the ledger up | 50 | 0 | 32 | 42 | 44.3 | 53 | 104 |
| C, pi2 to pi3 with xrpld frozen by SIGSTOP | 10 | 0 | 37 | 39 | 41.1 | 47 | 47 |

The gateway RPC stopped answering for the whole of series C, the watcher of
pi3 logged the chain as unreachable, and the payments continued unchanged. The
payee kept handing pre-signed blobs to the tower during the freeze, with round
trips of 41 ms for the last two claims, because the tower runs on the gateway
and needs no ledger for that. After SIGCONT the cooperative close by pi3 took
1202 ms and paid out 0.06 XRP.

The claim round trip consists of the ed25519 signature of the payer (6.4 ms),
one TCP connection over the mesh, the verification by the payee (7 to 12 ms)
and two fsyncs of the JSON state file. All of it runs in pure Python.

## Resource use at the end of the latency run

| Process | RSS | CPU |
|---|---|---|
| xrppay node on pi2, the payer | 48 MB | 1.5 percent |
| xrppay node on pi3, the payee that feeds the tower | 65 MB | 5.0 percent |
| xrppay tower on the gateway | 54 MB | 1.9 percent |
| xrpld on the gateway | 440 MB | 0.1 percent |

The Python environment is 36 MB and the stripped xrpld binary 52 MB. CPU is
the average over the lifetime of the process.

## What the arm shows

The payee must redeem within the settle delay, and without a tower a payee
that returns after the window loses everything it is owed. The tower closes
that gap with a pre-signed blob and no key of its own, because xrpld lets only
the destination redeem and the blob is the own signed transaction of the
destination. A Ticket keeps the blob valid however many transactions the payee
sends on its own, and a new blob after every claim keeps the tower at most one
claim behind, for about 40 ms of background work per payment.

