# LNMesh three Pi regtest experiment

This folder deploys the supplied LNMesh LND design to `brady@pi1gateway`,
`brady@pi2`, and `brady@pi3` and records fresh experimental evidence. The
neighboring Core Lightning implementation is a different project. The archive
under `LNMesh-2026-09-05/` is preserved reference material; its September 3 logs
are not results from this experiment.

The operational nodes are Bitcoin regtest only. The gateway runs Bitcoin Core
29.1 and LND 0.19.2-beta. The two leaves run LND with Neutrino connected only to
the gateway. All three use the onboard Wi-Fi interface with batman-adv.

## Run from this PC

PowerShell and Python 3.10 or later are sufficient for deployment and tests.
The launcher asks for the sudo password once per invocation. SSH continues to
use this PC's key. The password is sent through stdin and is not saved in scripts,
evidence, sudoers, or a remote credential file.

```powershell
.\experiment\run.ps1 -Phase status
```

The deployment and test order on **fresh Pis** is:

```powershell
.\experiment\run.ps1 -Phase deploy
.\experiment\run.ps1 -Phase bootstrap
.\experiment\run.ps1 -Phase funding
.\experiment\run.ps1 -Phase links
.\experiment\run.ps1 -Phase payments
.\experiment\run.ps1 -Phase closes
.\experiment\run.ps1 -Phase baseline
.\experiment\run.ps1 -Phase breach
.\experiment\run.ps1 -Phase reboot
.\experiment\run.ps1 -Phase metadata
```

`bootstrap`, `funding`, and `breach` have freshness checks. These are sequential
experiments with persistent state, not reset commands. If a phase fails, inspect
the journal and live state before deciding which step to resume. Do not rerun the
whole sequence on a populated testbed. `status` is read-only.

## Management after isolation

The leaves intentionally have no Ethernet IP address or default route. Their
cables can remain physically attached; NetworkManager autoconnect is disabled.
Use these commands from the PC (the key remains on the PC):

```powershell
ssh brady@pi1gateway
ssh -J brady@pi1gateway -o HostKeyAlias=pi2 brady@10.10.0.2
ssh -J brady@pi1gateway -o HostKeyAlias=pi3 brady@10.10.0.3
```

On an interactive Pi session, use `sudo lncli-mesh getinfo` or
`sudo lncli-mesh listchannels`. The gateway also has `sudo bcli getblockchaininfo`.
This demonstration mines only when explicitly requested; no continuous miner
is installed. Lightning payments over active channels do not require new blocks.

To restore a leaf's LAN connection over its mesh SSH session, run:

```bash
sudo /usr/local/sbin/lnmesh-restore-lan
```

This re-enables its original Ethernet profile and invalidates the offline test
condition until it is isolated and checked again. If mesh access is unavailable,
the same command can be run from the Pi's local console. Network changes use a
five minute rollback timer, cancelled after a fresh successful mesh SSH check.

## Files and measurement definitions

- `scripts/`: adapted deployment scripts and the on-Pi monotonic CLI timer.
- `runner.py`: native SSH transport, per-command timestamps, exit status, logs,
  and SHA-256 digests.
- `experiment.py`: assertions, regtest demonstrations, and measurement series.
- `verification.py`: reboot persistence and final host/clock metadata.
- `evidence/events.jsonl`: controller UTC command start/end journal.
- `evidence/outcomes.jsonl`: observations, wallet balances, channel states,
  transaction data, and payment timing from the originating Pi.
- `report/`: detailed writeup, PDF, figures, and derived tables.

Payment `local_cli_elapsed_ms` includes the local runuser/lncli process, RPC,
routing, and settlement. It excludes SSH establishment, sudo authentication,
invoice creation, and the later recipient verification. `htlc_elapsed_ms` uses
the payment attempt and resolution timestamps reported by LND. The measurement
script uses `time.perf_counter_ns()` for local CLI durations.

The breach experiment creates a second, disposable LND instance on pi3. Its
directories and ports are separate from pi3's main node. It restores only this
disposable instance's stale state, then stops it after the experiment. Its stale
files are retained on pi3 for evidence and should not be started as an ordinary
node. The main three-node triangle retains its original identities.

The report generator uses `reportlab`, `matplotlib`, `markdown`, and `pypdf` in
addition to the standard library. These are local reporting dependencies and are
not required on the Pis. Figures and data use the fresh evidence files only.

Generate the report with `python experiment/build_report.py` after completing
verification and `python experiment/supplement.py`. The latter verifies the
confirmed breach transaction outputs and records local provenance. Reporting
requires the complete evidence set; it is not a deployment phase.

The final mesh setup persists each bat0 MAC address across reboots. This fixed
stale neighbor mappings discovered during the first reboot checks. The report
documents the assisted initial recovery and the later automatic recovery trials.
Four early preflight/install stdout files suffered filename collisions; the
evidence audit lists them explicitly. No payment or channel result is taken from
those affected files. The final combined launcher has not been replayed on erased
Pis; its constituent operations and the deployed final configuration were tested.
