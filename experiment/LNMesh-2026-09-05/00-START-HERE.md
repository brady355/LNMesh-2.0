# LNMesh handoff, 2026-09-05

Offline Lightning channels over a Raspberry Pi mesh. Built and demonstrated
on 2026-09-03 on three Raspberry Pi 5s. Everything in this folder is what
exists; nothing is planned-but-unbuilt except where a file says so.

## Read in this order

1. `report/lnmesh-overview.html`  Open in a browser. TL;DR at the top, then
   the build, the six demo results, the two findings, threat model,
   measurements, gaps, next steps. 10 minutes.
2. `PLAN.md`  Why each decision was made. Threat model in section 5.
   Sections 8 to 10 were updated after the build to match what happened.
3. `DOCUMENTATION.md`  How to rebuild from blank SD cards. Every phase and
   demo has the exact commands, a Verify block, and an Observed line with
   the real result, including the two demos that failed on their first run.
4. `README.md`  The runbook: results summary and the six demo logs verbatim.
5. `results/2026-09-03/`  Raw logs of every demo, link measurements, and
   `measurements.md` (latencies, throughput, block gaps) for the paper.

`report/lnmesh-plan.html` is the pre-build plan as a web page, kept for
comparison with what was actually built.

## What is in here

| Path | Contents |
|---|---|
| `scripts/common/` | base OS, mesh script and unit installer, chrony ordering fix, LND install and config (bitcoind or Neutrino backend) |
| `scripts/gateway/` | chrony server, Bitcoin Core install and config, no-forwarding sysctl, block filters for Neutrino |
| `scripts/offline/` | chrony client with wait-for-gateway, isolation (wired profile off, Bluetooth blocked) |
| `scripts/demo/` | `lib.sh` plus `1-fund` to `6-breach`; each prints every remote command and logs to `results/<date>/` |
| `units/` | systemd units for the mesh, bitcoind, and lnd |
| `ssh/config.example` | laptop SSH config: A direct, B and C via ProxyJump through A |
| `hosts.env.example` | addresses, users, node pubkeys. RPC password redacted |
| `related-works/` | the related-works draft this project responds to |

## What you need to reproduce it

- Three Raspberry Pi 5s, three microSD cards, one Ethernet cable each for
  the bring-up phase. No USB WiFi adapters; the onboard radio does IBSS.
- A laptop with SSH. Phase 0 of `DOCUMENTATION.md` is the only manual part.
- No real bitcoin. Everything is regtest.

## Things to know

- B and C end up with no Ethernet at all; the laptop reaches them by SSH
  jumping through A over the mesh. Do not skip Phase 6.2 before pulling
  cables.
- Demo 6 deliberately corrupts C's channel database. Regtest only, ever.
- The RPC password is generated on A during Phase 4. Fill `BTC_RPC_PASS` in
  your own `hosts.env` from `/etc/lnmesh/rpcauth.txt` on A, and pass it as the
  fourth argument to `scripts/common/05-lnd-config.sh` (usage line in the script).
- Two findings worth citing: LND with a remote bitcoind backend cannot start
  a payment while that backend is down (so the offline nodes run Neutrino),
  and a breach was detected and punished one block after the stale state
  confirmed, with the victim on a light client fed only by the gateway.

## Rebuilding on your own three Pis

You do not need Claude Code. Everything is plain bash over SSH.

1. Phase 0 by hand, from `DOCUMENTATION.md`: flash three cards (SSH on,
   your public key), cable all three to your router, reserve their
   addresses, create `~/.ssh/config` entries `lnmesh-a`, `lnmesh-b`,
   `lnmesh-c` (see `ssh/config.example`; until Phase 6.2, point lnmesh-b and
   lnmesh-c at the Ethernet addresses), confirm passwordless sudo.
   If the imager's customisation does not apply, section 0.6a has the
   console fix; it happened on all three cards in this build.
2. `cp hosts.env.example hosts.env` and fill in your management addresses,
   router address, and login users. Keep the mesh addresses.
3. Run the phases in order and read each one's output before the next:

   ```
   ./scripts/build.sh check     # all three: ssh, sudo, internet, IBSS support
   ./scripts/build.sh 1         # packages, wlan0 unmanaged, reboots all three
   ./scripts/build.sh 2         # mesh; expect two neighbours on each Pi
   ./scripts/build.sh 3         # time; expect ^* 10.10.0.1 on B and C
   ./scripts/build.sh 4         # bitcoind on A; writes BTC_RPC_PASS into hosts.env
   ./scripts/build.sh 5         # lnd on all three; mines 101; writes PK_A/B/C
   ./scripts/build.sh 6.1       # A stops forwarding
   ./scripts/build.sh 6.2       # prints the ProxyJump config; edit ~/.ssh/config, then
   ./scripts/build.sh 6.2 test  # must reach B and C through A
   ```
   Now unplug Ethernet from B and C, then:
   ```
   ./scripts/build.sh 6.3       # wired profile off, Bluetooth off, isolation checks
   ./scripts/build.sh status    # one line per Pi
   ```
4. Demos, in order: `./scripts/demo/1-fund.sh` through `6-breach.sh`.
   Each appends to `results/<today>/`. Demo 6 is regtest only.

Honest caveat: the phase scripts under `scripts/` are exactly what was run
on 2026-09-03, but `scripts/build.sh` itself, which strings them together,
was written afterwards for this handoff and has not been run end to end on
fresh Pis. If a phase misbehaves, `DOCUMENTATION.md` has the same commands
step by step, with the expected output of each.

## Differences you may hit

- Your router assigns different addresses; that is what `hosts.env` and
  `~/.ssh/config` are for. The mesh addresses 10.10.0.1/2/3 stay.
- Software versions are pinned in the install scripts (Bitcoin Core 29.1,
  LND 0.19.2-beta). Newer is probably fine; change the version in the
  script and the version log together.
- A Pi other than a Pi 5 may lack IBSS support; `build.sh check` tells
  you. The fallback is an Atheros AR9271 USB adapter.
