# LNMesh: Offline Lightning Channels over a Raspberry Pi Mesh

Planning document, written before the build. Built and demonstrated on
2026-09-03; see `DOCUMENTATION.md` for the procedure and observed results and
`README.md` for the runbook. Sections 5, 9 and 10 below were updated after
the build to reflect what was actually observed.

## 1. Goal

Three Raspberry Pi 5s form a WiFi mesh with batman-adv. One (A) has
internet. Two (B, C) do not. All three run Lightning nodes.

Prior work (LNMesh, Kurt et al. 2023) showed offline nodes can *pay* over
channels that were opened while online. This project's contribution is
that offline nodes can also *open and close* channels, with no internet
and no prior setup, because a gateway node on the mesh relays their
on-chain transactions and their view of the chain.

The proof of concept is done when, with B and C having no internet:

1. **Offline funding.** B and C receive on-chain funds. The transactions
   reach the chain only through A.
2. **Offline open.** B opens a channel to C. The funding transaction is
   broadcast and confirmed only through A. Neither B nor C touches the
   internet.
3. **Offline pay.** B pays C, B pays A, A pays B.
4. **Offline close.** B cooperatively closes a channel, and separately
   force-closes one. Both closing transactions and the later sweep reach
   the chain only through A.
5. **Baseline replication.** With A's bitcoind stopped, B still pays C.
   This is the LNMesh result, kept because it is a good demo.
6. **Breach response (stretch).** C publishes an old channel state. B
   detects it via A and its penalty transaction confirms. This is the
   scenario papers [2] and [3] in the related works worry about.

Related works draft: `Brady_Landry_Related_Works_Draft1.pdf`.

## 2. Decisions made

| Decision | Choice | Why |
|---|---|---|
| Hardware | 3x Raspberry Pi 5 | On hand. Plenty of RAM for every role. |
| Mesh | batman-adv over ad-hoc WiFi | Layer 2 multi-hop, static IPs survive path changes. |
| Chain | regtest on A | Blocks on demand, instant funding, no sync, no real money. |
| Lightning | LND on all three | Static linux-arm64 binary. `noseedbackup` on regtest skips interactive wallet creation, which matters when everything is driven over SSH. |
| Chain backend for B, C | **Neutrino with A as sole peer** (changed during the build; was A's bitcoind RPC) | Demo 5 showed LND's router needs a live `getblockchaininfo` from a bitcoind backend to start a payment, so B and C could not pay while A's bitcoind was down. Neutrino keeps the best-block view local, and A serves compact block filters. Every on-chain read and broadcast from B and C still goes through A. |
| Channel timelock | Long remote delay on mesh channels, e.g. 1008 blocks | Offline nodes need a wide window to return and punish a cheat. LND: `bitcoin.defaultremotedelay`. Justified by [2], [3]. |
| Management | Claude Code over passwordless SSH from the laptop | Everything scripted, nothing interactive. |
| Time | chrony, A serves B and C | Pis have no RTC. HTLC timeouts and invoice expiry need sane clocks. |

Why LND rather than CLN for the MVP: CLN is lighter and has a nicer
plugin story, but on Raspberry Pi OS arm64 it means building from source,
trusting an Ubuntu tarball, or running Docker. LND is one tarball with
`lnd` and `lncli` in it. Switching to CLN later is a valid experiment.

## 3. Topology

```
   home LAN / internet (Ethernet)
              |
         +---------+
         |  Pi A   |  gateway: bitcoind regtest, lnd, chrony server
         |10.10.0.1|
         +---------+
          /       \        WiFi ad-hoc + batman-adv (bat0)
         /         \
  +---------+   +---------+
  |  Pi B   |---|  Pi C   |  offline: lnd only
  |10.10.0.2|   |10.10.0.3|
  +---------+   +---------+
```

Lightning channels: A-B, A-C, B-C. All peer connections, RPC, ZMQ, and
NTP use the `10.10.0.x` mesh addresses on `bat0`, so every payment and
every on-chain transaction from B or C really crosses the mesh.

## 4. How offline open and close works

Nothing custom. Stock LND with a remote bitcoind does all of this. The
point of the MVP is to show it working end to end over a mesh and to
name the trust it requires.

**What an offline node needs from the chain**

| Operation | Needs from A's bitcoind |
|---|---|
| Receive on-chain funds | See the transaction and its confirmations |
| Open a channel | A UTXO to spend, fee estimate, broadcast funding tx, watch for confirmations |
| Pay over a channel | Nothing. Peer connection only. |
| Cooperative close | Broadcast closing tx. Peer must be reachable over the mesh. |
| Force close | Broadcast commitment tx, then after the timelock broadcast the sweep |
| Detect a breach | See the counterparty's old commitment tx in a block, broadcast the penalty tx |

Every row except "pay" is satisfied by A's bitcoind RPC and ZMQ over
`bat0`. That is why B and C can do all of it with no internet.

**Funding story.** A node with nothing on-chain cannot open a channel.
The MVP demonstrates both realistic paths:

- **Inbound channel.** A opens a channel to B and pushes balance. B needs
  no on-chain funds and can start paying immediately.
- **On-chain relay.** A's wallet pays B on-chain. On mainnet this would be
  anyone paying B; the transaction still enters the chain via A. B then
  uses that UTXO to open B-C.

**Regtest quirks.** `estimatesmartfee` has no data on regtest, so LND
falls back to a static fee rate. Confirmations only happen when A mines,
so the demo scripts mine explicitly after each broadcast.

## 5. Threat model

The related works stress that a channel must be watched while it is
closing or an old state can be published. In this topology A is both the
chain oracle for B and C *and* a channel counterparty on A-B and A-C.
That is a conflict the write-up has to state plainly.

**Case 1: A is honest, C cheats while B is off the mesh.**
C force-closes B-C with an old state. B is isolated and cannot see it.

- Mitigation in the MVP: a long remote delay on the channel. C's funds
  stay locked for that many blocks, giving B time to reconnect and have
  its LND broadcast the penalty via A.
- Follow-up mitigation: LND's watchtower on A watching the B-C channel.
  A is not a counterparty there, so A as watchtower is sound.
- Demonstrated by the breach test in section 7.

**Case 2: A cheats.**
A force-closes A-B with an old state and filters what its bitcoind
reports to B, so B never sees the breach.

- Mitigated in the build (originally planned as a follow-up): B and C run
  Neutrino with A as their only peer, verifying headers and proof of work
  themselves. A can still withhold blocks, but cannot forge them.
- What was done: B and C as Neutrino light clients with A as their only
  peer, bitcoind on A with `blockfilterindex=1` and
  `peerblockfilters=1`, P2P bound on the mesh address. Demo 6 showed B
  detecting a breach from A's filters and punishing it within one block.
  Withholding remains possible and is
  detectable from stale block timestamps. This moves A from "trusted" to
  "can censor, cannot lie".
- Not solvable within this topology by watchtowers, since any tower B
  could reach also goes through A.

**Out of scope.** Papers [2] (CRAB) and [3] propose new channel
constructions that resist timelock bribery and reduce monitoring. They
need custom channel protocols and cannot be built on stock LND. They are
discussion material for the write-up, and the long-timelock choice above
is the practical response the MVP can make.

## 6. Networks: mesh vs management

Two separate networks on each Pi. Keeping them apart is what makes
"offline" honest while still letting Claude Code reach B and C.

**Mesh (`wlan0` -> `bat0`, 10.10.0.0/24).** Carries Lightning, bitcoind
RPC/ZMQ, NTP. A does not forward internet traffic onto it.

**Management (`eth0`, home LAN).** SSH only.
- A: normal DHCP, default route, internet.
- B, C: Ethernet only during bring-up (phases 1 to 5). Final state: cable
  unplugged, wired profile disabled, only bat0. Laptop reaches them via
  `ProxyJump lnmesh-a` over the mesh. A has IP forwarding off. Verify with
  `curl https://example.com` failing from B.

Bring-up keeps the cable on B and C because the mesh cannot be configured
before there is a way in. The switch to jump-host access happens after the
mesh is proven and LND is installed, not during bring-up.

Management prerequisites on all three:
- `ssh-copy-id` from the laptop, one key.
- `~/.ssh/config` entries `lnmesh-a`, `lnmesh-b`, `lnmesh-c`.
- Passwordless sudo for the login user (`NOPASSWD` in sudoers).
- Long-lived processes (bitcoind, lnd, mesh setup) run as systemd units
  so they survive SSH sessions ending.

### Mesh bring-up

Raspberry Pi OS Bookworm uses NetworkManager, which will fight a manual
ad-hoc interface. Steps per Pi:

1. Set WiFi country (`raspi-config nonint do_wifi_country XX`) or the radio
   stays rfkill-blocked.
2. Tell NetworkManager to leave `wlan0` unmanaged.
3. `apt install batctl`. The `batman-adv` kernel module ships with the Pi
   kernel.
4. systemd unit at boot: `iw wlan0 set type ibss`, bring it up,
   `iw wlan0 ibss join lnmesh 2412`, `batctl if add wlan0`, bring up
   `bat0`, assign `10.10.0.x/24`.
5. Verify: `batctl n` lists the other two, `ping` works across `bat0`.

Check first: `iw list` must show `IBSS` under supported interface modes.
Pi 4's onboard radio does; confirm on Pi 5 before assuming. Fallback is a
USB adapter with an Atheros chipset (ath9k_htc, e.g. AR9271).

The ad-hoc link is unencrypted in the MVP. Lightning traffic is encrypted
end to end (Noise) and bitcoind RPC uses rpcauth. Known gap.

## 7. Bring-up and demo sequence

Order matters. bitcoind must be reachable before any lnd starts. Every
step is a one-line `ssh lnmesh-x '...'` command.

**Infrastructure**

1. **A: bitcoind regtest.** `rpcbind=10.10.0.1` and localhost,
   `rpcallowip=10.10.0.0/24`, `rpcauth=...`,
   `zmqpubrawblock=tcp://10.10.0.1:28332`,
   `zmqpubrawtx=tcp://10.10.0.1:28333`. systemd unit.
2. **chrony.** A serves `10.10.0.0/24`. B, C use A as their only source.
3. **lnd on all three.** `bitcoin.regtest=1`, `bitcoin.node=bitcoind`,
   `bitcoind.rpchost=10.10.0.1`, ZMQ endpoints, `listen=10.10.0.x:9735`,
   `externalip=10.10.0.x`, `noseedbackup=true`,
   `bitcoin.defaultremotedelay=1008`. On B and C a wait-for-A loop before
   start. All channels opened `--private`.
4. A mines 101 blocks to its own lnd address.

**Demo 1: offline funding**

5. A opens A-B with `--push_amt`. B now has balance with zero on-chain
   funds. A mines 6.
6. A's lnd pays C on-chain. A mines 6. C sees the UTXO through A.
   A also pays B on-chain so B can fund the next step.

**Demo 2: offline open**

7. B connects to C over `bat0` and opens B-C. `lncli pendingchannels` on
   B shows the funding tx. A mines 6. `lncli listchannels` on both shows
   it active. A opens A-C as well so every pair has a channel.

**Demo 3: offline pay**

8. C invoices, B pays. Then B->A and A->B.

**Demo 4: offline close**

9. B cooperatively closes A-B. A mines 1. B's on-chain balance updates.
10. B force-closes B-C. A mines 1, then mines `remotedelay` more. B's
    sweep confirms and `lncli walletbalance` on B reflects it.
11. Reopen B-C for the remaining demos.

**Demo 5: baseline replication**

12. `systemctl stop bitcoind` on A. C invoices, B pays. Succeeds. Start
    bitcoind, confirm all three lnds recover.

**Demo 6: breach response (stretch)**

13. Stop lnd on C. Copy C's `channel.db` aside. Start lnd on C.
14. Make several B->C payments so C's old state is worth less to B's
    counterparty than the current one.
15. Stop lnd on C. Restore the old `channel.db`. Start lnd on C.
    Force-close B-C from C. C broadcasts the stale commitment via A.
16. A mines 1. B's lnd sees the breach through A and broadcasts the
    penalty. A mines 1. B's wallet holds the entire channel balance.

This is the only demo that needs care: restoring an old `channel.db` is
deliberate self-sabotage and must never be done outside regtest.

## 8. Definition of done (all met 2026-09-03)

- `batctl n` on each Pi shows the other two.
- B and C cannot reach the internet (checked, not assumed).
- Demo 1: B has balance with no on-chain funds. C received on-chain
  funds via A.
- Demo 2: B-C channel opened by B, funding tx confirmed via A.
- Demo 3: B->C, B->A, A->B payments succeed.
- Demo 4: cooperative close and force close both settle on-chain via A,
  and the force-close sweep arrives after the timelock.
- Demo 5: B->C payment succeeds while bitcoind on A is stopped.
- Stretch: breach test ends with B holding the full B-C balance.
- README records every command and its observed output.

Every line above was checked in the build; the evidence for each is in the
Observed lines of `DOCUMENTATION.md` Phases 2 to 7 and in `results/`.

## 9. Known gaps, as observed after the build

- A can still censor: B and C see only what A relays. Neutrino means A
  cannot lie about blocks, but a withheld block is invisible until B or C
  notices stale timestamps. Not tested.
- No watchtower. Case 1 relies on the 1008-block delay alone, which Demo 4
  confirmed is enforced (`blocks_til_maturity` 1008) and Demo 6 confirmed
  is enough time when B returns.
- LND with a bitcoind backend cannot start a payment while that backend is
  down (Demo 5 run 1). Any node that keeps the bitcoind backend, i.e. A,
  has this limitation. B and C do not, because of Neutrino.
- LND exits cleanly after about 5 minutes without a chain backend
  (health check). `Restart=always` covers it, but a node is blind for
  that interval. Neutrino nodes keep the check local.
- Ad-hoc WiFi link is unencrypted. Lightning and P2P on it are still
  encrypted or authenticated. Measured 48 Mbit/s B to A, RTT 1 to 7 ms.
- No public network reach: regtest has no public nodes.
- Wallets use `noseedbackup`. Fine on regtest, never on mainnet.
- No channel state backups outside the breach test's deliberate copy.
- Resetting a node (section 8.3) changes its identity, which orphans its
  channels on the other side until they are force-closed. Seen in Demo 6.
- After a long mine (1008 blocks) a wallet needs seconds to rescan before
  it can fund a channel (Demo 4 run 1). On regtest only; mainnet never
  jumps 1008 blocks.
## 10. Follow-ups, in rough order of value

1. ~~**Neutrino on B and C with A as sole peer.**~~ Done during the build
   after Demo 5 run 1. Directly addresses threat
   model case 2. Biggest security improvement available in this topology.
   Remaining question: detect a withholding A from stale block timestamps.
2. **Watchtower on A for the B-C channel.** Addresses case 1 without
   relying on the timelock alone. LND has one built in.
3. **Signet.** A opens a channel to a public signet node. B pays a node on
   the internet via A. A public node pays B via a route hint. B opens a
   channel to a public node through A. "Offline node reaches the world."
4. **Isolation tests.** Take B off the mesh for N minutes during a pending
   close and during normal operation. Record how LND recovers.
5. **Multi-hop mesh reroute.** Block the B-A radio path and show B still
   reaches A via C at the batman-adv layer.
6. **Tiny app layer.** LND REST on B and C, one web page: invoice QR, pay
   invoice. Phone on B's hotspot pays C.
7. **Encrypt the mesh link** with wpa_supplicant in IBSS-RSN mode.
8. **CLN on one or all nodes**, as the paper mixed implementations.
9. **Mainnet with pocket change**, only after seed backups, channel
   backups, encryption, and Neutrino or a watchtower are in place.

## 11. Repo layout when code starts

```
LNMesh/
  PLAN.md                why: decisions, threat model, follow-ups
  DOCUMENTATION.md       how: reproducible build and demo procedure, lab record
  README.md              runbook: commands and their observed output
  ssh/config.example     lnmesh-a/b/c host entries
  hosts.env              management IPs, mesh IPs, roles
  scripts/
    common/              hostname, sudo, chrony, batman-adv unit
    gateway/             bitcoind, lnd, chrony server
    offline/             lnd, chrony client, drop default route
    demo/
      1-fund.sh          inbound channel + on-chain relay
      2-open.sh          B opens B-C via A
      3-pay.sh           three payments
      4-close.sh         cooperative + force close + sweep
      5-baseline.sh      pay with bitcoind stopped
      6-breach.sh        stale channel.db, penalty tx (regtest only)
  units/                 systemd unit files
```

Each script is idempotent and run as `ssh lnmesh-x 'sudo bash -s' <
scripts/...`. No Ansible for an MVP with three hosts.

## 12. References

- [1] LNMesh, Kurt et al., WoWMoM 2023: https://arxiv.org/abs/2304.14559
- [2] Aumayr et al., "Securing Lightning Channels Against Rational
  Miners," CCS 2024. doi:10.1145/3658644.3670373
- [3] Ying et al., "A New Bi-Directional Payment Channel Without
  Third-Party Monitoring," ACISP 2024. doi:10.1007/978-981-97-5101-3_7
- Full list: `Brady_Landry_Related_Works_Draft1.pdf`
- batman-adv: https://www.open-mesh.org/projects/batman-adv/wiki
- LND docs: https://docs.lightning.engineering
- LND bitcoind backend: https://docs.lightning.engineering/lightning-network-tools/lnd/run-lnd
- Bitcoin Core: https://bitcoincore.org/en/doc/
- BOLT specs: https://github.com/lightning/bolts
