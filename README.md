# LNMesh: mesh experiment and lifecycle code

The September 2026 experiment deployed Bitcoin Core 29.1 and LND 0.19.2-beta
on three Raspberry Pi 5s. Two leaves used a Wi-Fi mesh and a gateway as their
only Bitcoin peer. All 150 measured payments settled; funding, channel opening,
cooperative and force closing, breach response, and reboot recovery were tested.

Start with the recorded experiment:

* [Headline findings](experiment/report/LNMesh-headline-findings.md)
* [Detailed research report](experiment/report/LNMesh-research-writeup.md)
* [Experiment setup and operations](experiment/README.md)
* [Evidence and scripts bundle](experiment/LNMesh-experiment-2026-09-07.zip)

The results are from one close-range regtest deployment. The reports document
the scope, limitations, implementation fixes, and known evidence defects.

## Separate Core Lightning implementation

The root-level installers and `lnmeshctl/` below implement a separate Core
Lightning control plane. The recorded September experiment validates the LND
implementation in `experiment/`; it does not validate these root-level installers
on the three Pis.

This repository contains installable **scripts and control-plane code** for the
LNMesh offline channel-lifecycle testbed. Clone it onto freshly installed
Raspberry Pi 5 systems running Raspberry Pi OS Lite 64-bit Trixie, then run the
gateway or leaf installer. The installers are idempotent and pin/checksum-verify
Bitcoin Core 31.1 and Core Lightning 26.06.7 ARM64 binaries.

The implementation is intentionally conservative:

* a SQLite journal is authoritative and uses `synchronous=FULL`;
* lifecycle operations are serialized across the deployment;
* a channel opening is staged before it can be published;
* mainnet channel amounts are hard-capped at 100,000 satoshis;
* scripts never print RPC credentials, mnemonics, PSBTs, or private keys.

## Install on the Pis

Use the same network, mesh name, and regulatory country on every Pi. Install
the gateway first:

```bash
git clone https://github.com/brady355/LNMesh-2.0.git LNMesh2.0
cd LNMesh2.0
sudo bash ./install-gateway.sh --country US --mesh-name field-test --network regtest
```

Copy the public enrollment key printed by the gateway to each leaf. It is a
public key, not a secret:

```bash
scp gateway:/var/lib/lnmesh/export/bootstrap_authorized_key.pub ./bootstrap.pub
```

Then run this on each leaf:

```bash
git clone https://github.com/brady355/LNMesh-2.0.git LNMesh2.0
cd LNMesh2.0
sudo bash ./install-leaf.sh --country US --mesh-name field-test --network regtest \
  --bootstrap-key ../bootstrap.pub
```

After all leaves advertise themselves on the mesh, run once on the gateway:

```bash
sudo lnmeshctl bootstrap --expect 2
```

The bootstrap displays the discovered Pi serials, MAC addresses, and SSH host
fingerprints for one confirmation. It then assigns static mesh addresses,
creates per-leaf RPC/control/tunnel credentials, starts the restricted tunnels,
and starts each fresh Lightning node. Testnet4 and mainnet bootstrap waits for
Bitcoin Core to synchronize before starting Lightning.

The installers need temporary Internet access for Debian packages and verified
release downloads. A leaf removes its default route only after those downloads
finish. Rerunning the same installer is supported; changing an initialized Pi's
Bitcoin network is refused.

## Local code check

```powershell
$env:LN_MESH_STATE_DIR = "$PWD\.state"
python -m unittest discover -s tests -v
python -m lnmeshctl status --json
python -m lnmeshctl channel open --from n01 --to n02 --amount-sat 1000 --stage-only --json
```

On a provisioned gateway, `lnmesh-lifecycle-worker` consumes durable operations
and uses the per-leaf forced-command RPC bridge. See `docs/DEPLOYMENT.md` for
the remaining physical validation contract.

## Layout

* `lnmeshctl/` — portable Python CLI, SQLite journal, and worker.
* `scripts/` — idempotent gateway/leaf networking and tunnel scripts.
* `systemd/` — services and timers to install in the eventual images.
* `config/` — deliberately non-secret configuration templates.

No configuration template contains a password, seed, or private key. Runtime
secrets are generated locally during bootstrap and installed with root-only
permissions.
