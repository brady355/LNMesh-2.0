# LNMesh Build Documentation

Reproducible procedure for building the LNMesh proof of concept from three
fresh Raspberry Pi 5s to a working offline Lightning channel open, pay, and
close over a batman-adv mesh. Companion to `PLAN.md`, which explains *why*.
This file records *how*.

**Status (2026-09-03).** All phases and all six demos complete; every
*Observed* line below is filled from the run. Phase 0 is done by hand. Phases 1 to 7 are run by Claude Code
over SSH. Every phase ends with a *Verify* block and an *Observed* line.
Fill in *Observed* as each phase is executed so this file doubles as the
lab record for the paper. Until a phase has an *Observed* entry, treat it
as procedure, not result.

**Automated path.** `scripts/build.sh <phase>` runs Phases 1 to 6.3 from the
laptop using `hosts.env`, invoking the same scripts under `scripts/` that
this document quotes. Phase 0 stays manual. The commands below are what the
driver runs, kept here so each step can also be done by hand.

**Conventions.**

- `laptop$` runs on the development machine. `A$`, `B$`, `C$` run on that
  Pi after `ssh lnmesh-a` (or b, c). `ALL$` means run on all three.
- Non-interactive SSH shells on Debian do not have `/usr/sbin` on PATH, so
  `iw`, `rfkill`, `batctl`, `modinfo` are called by full path or via `sudo`.
- Commands that need root are written with `sudo`. Passwordless sudo is a
  Phase 0 requirement.
- Mesh addresses are fixed: A `10.10.0.1`, B `10.10.0.2`, C `10.10.0.3`.
  Management (Ethernet) addresses are whatever your router assigns; the
  examples use `192.168.1.11/12/13`. Record yours in the version log.
- Pinned software versions are in the version log (section 10). If you
  change one, change it there and in the download step, nowhere else.

---

## 0. Manual setup (hands on the hardware)

Everything in this phase needs physical access or a first login. After it,
no keyboard or monitor is ever attached to a Pi again.

### 0.1 Development machine

1. Generate an SSH key if none exists.

   ```
   laptop$ ssh-keygen -t ed25519 -C lnmesh
   laptop$ cat ~/.ssh/id_ed25519.pub
   ```

2. Install Raspberry Pi Imager (https://www.raspberrypi.com/software/).

### 0.2 Flash three cards

For each Pi, in Raspberry Pi Imager:

| Screen | Setting |
|---|---|
| Device | Raspberry Pi 5 |
| OS | Raspberry Pi OS Lite (64-bit) |
| Storage | the microSD card (32 GB or larger) |
| Customisation: General | Hostname `lnmesh-a` / `lnmesh-b` / `lnmesh-c`. Username `mesh-user-a` / `mesh-user-b` / `mesh-user-c`, any password. Locale and timezone. **Leave "Configure wireless LAN" unchecked**; `wlan0` is reserved for the mesh. |
| Customisation: Services | Enable SSH, "Allow public-key authentication only", paste the public key from 0.1. |

Write, then label the cards A, B, C physically.

### 0.3 Cable and power

- One Ethernet cable from each Pi to the home router or switch.
- Official 27 W USB-C supply for each Pi 5.
- Nothing on `wlan0`. No monitor needed.

All three Pis keep Ethernet and internet during Phases 1 to 5 so packages can be
installed. B and C lose the cable entirely in Phase 6, after everything is installed.

### 0.4 Pin management addresses

Find the three Pis on the router's DHCP client list (or
`ping lnmesh-a.local`). Create DHCP reservations so the addresses never
change. Record them:

```
laptop$ cat > ~/Projects/LNMesh/hosts.env <<'EOT'
MGMT_A=192.168.0.130
MGMT_B=192.168.0.132
MGMT_C=192.168.0.131
MESH_A=10.10.0.1
MESH_B=10.10.0.2
MESH_C=10.10.0.3
SSH_USER_A=mesh-user-a
SSH_USER_B=mesh-user-b
SSH_USER_C=mesh-user-c
EOT
```

### 0.5 SSH config and first login

```
laptop$ cat >> ~/.ssh/config <<'EOT'
Host lnmesh-a
  HostName 192.168.0.130
  User mesh-user-a
Host lnmesh-b
  HostName 192.168.0.132
  User mesh-user-b
Host lnmesh-c
  HostName 192.168.0.131
  User mesh-user-c
EOT
laptop$ for h in a b c; do ssh lnmesh-$h hostname; done
```

Answer `yes` to the three host-key prompts. This is the only interactive
step.

### 0.6 Verify the hand-off conditions

All nine commands must succeed with no prompt:

```
laptop$ for h in a b c; do
  ssh lnmesh-$h true                                  && echo "$h ssh ok"
  ssh lnmesh-$h sudo -n true                          && echo "$h sudo ok"
  ssh lnmesh-$h 'curl -sI https://deb.debian.org | head -1' && echo "$h internet ok"
done
```

If `sudo -n true` prompts, the imager's user was not given NOPASSWD.
Fix once per Pi:

```
ALL$ echo "$(id -un) ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/010_lnmesh-nopasswd
ALL$ sudo chmod 440 /etc/sudoers.d/010_lnmesh-nopasswd
```

### 0.6a If the imager customisation did not apply (what happened in this build)

Symptom: the Pis get DHCP leases but SSH is refused on all of them. Cause:
the imager only writes its settings if you answer **Yes** on the "apply OS
customisation" prompt after choosing storage. Without it the Pi boots to
the first-run user wizard with no SSH, no user, no key.

Fix without reflashing. Attach a monitor and keyboard to each Pi once:

1. In the wizard, create the user (`mesh-user-a` on A, and so on).
2. At the console, logged in as that user:

   ```
   sudo hostnamectl set-hostname lnmesh-a          # b, c on the others
   echo "127.0.1.1 lnmesh-a" | sudo tee -a /etc/hosts
   sudo systemctl enable --now ssh
   echo "$(id -un) ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/010_lnmesh-nopasswd
   ```

3. From the laptop, install the key with the password once:

   ```
   laptop$ ssh-copy-id -i ~/.ssh/id_ed25519.pub mesh-user-a@192.168.0.130
   ```

Locale, timezone and WiFi country are then set over SSH in Phase 1.

### 0.7 Confirm the radio supports ad-hoc mode

The mesh needs IBSS. Check before anything else, because the fallback is
buying hardware:

```
ALL$ /usr/sbin/iw list | sed -n '/Supported interface modes/,/^$/p'
```

`* IBSS` must appear. If it does not, use one Atheros AR9271 USB adapter
per Pi and substitute its interface name for `wlan0` throughout.

**Observed (2026-09-03):**
- A: Raspberry Pi 5 Model B Rev 1.1, 8 GB, 128 GB card. Debian 13 (trixie),
  kernel 6.18.34+rpt-rpi-2712. `iw list` shows IBSS, managed, AP, P2P;
  `join_ibss` in supported commands. Driver brcmfmac. rfkill unblocked,
  reg domain US already set. batman-adv 2025.4 module present. Onboard
  radio is sufficient, no USB adapter.
- B (.132): identical hardware, kernel and radio results to A. IBSS yes.
- C (.131): identical hardware, kernel and radio results to A. IBSS yes.
- Phase 0 complete 2026-09-03. The imager customisation did not apply on any
  card; all three were fixed at the console per 0.6a.

---

## 1. Base OS configuration

Run on all three Pis. Idempotent.

```
ALL$ sudo apt update && sudo apt full-upgrade -y
ALL$ sudo apt install -y batctl chrony iw curl jq
ALL$ sudo raspi-config nonint do_wifi_country US     # your ISO 3166 code
ALL$ sudo rfkill unblock wlan
ALL$ sudo tee /etc/NetworkManager/conf.d/99-lnmesh-unmanaged.conf >/dev/null <<'EOT'
[keyfile]
unmanaged-devices=interface-name:wlan0
EOT
ALL$ sudo systemctl restart NetworkManager
ALL$ sudo reboot
```

**Verify**

```
ALL$ nmcli device status | grep wlan0        # expect: wlan0 wifi unmanaged
ALL$ rfkill list wlan | grep -i blocked      # expect: Soft blocked: no, Hard blocked: no
ALL$ modinfo batman-adv | head -1            # module exists in the Pi kernel
ALL$ uname -r; batctl -v
```

**Observed (2026-09-03):** all three: kernel 6.18.34+rpt-rpi-2712, batctl
debian-2025.0-2, chrony 4.6.1, iw 6.9, wlan0 unmanaged after restart. 200
packages upgraded on the fresh image. Timezone America/Chicago.

---

## 2. Mesh bring-up (batman-adv over IBSS)

### 2.1 Install the mesh script and unit

Same files on all three; only the address argument differs.

```
ALL$ sudo tee /usr/local/sbin/lnmesh-mesh.sh >/dev/null <<'EOT'
#!/bin/bash
# Bring up wlan0 as an IBSS cell and attach it to batman-adv as bat0.
set -euo pipefail
MESH_IP="$1"
IFACE="${2:-wlan0}"
SSID=lnmesh
FREQ=2412                     # channel 1
BSSID=02:CA:FE:00:00:01       # fixed cell id: prevents IBSS partitioning

modprobe batman-adv
ip link set "$IFACE" down
iw dev "$IFACE" set type ibss
ip link set "$IFACE" up
iw dev "$IFACE" set power_save off
iw dev "$IFACE" ibss leave 2>/dev/null || true
iw dev "$IFACE" ibss join "$SSID" "$FREQ" fixed-freq "$BSSID"
batctl if add "$IFACE"
ip link set bat0 up
ip addr replace "${MESH_IP}/24" dev bat0
EOT
ALL$ sudo chmod 755 /usr/local/sbin/lnmesh-mesh.sh
```

Unit (replace `10.10.0.1` with `.2` on B and `.3` on C):

```
A$ sudo tee /etc/systemd/system/lnmesh-mesh.service >/dev/null <<'EOT'
[Unit]
Description=LNMesh batman-adv mesh on wlan0
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/lnmesh-mesh.sh 10.10.0.1
ExecStop=/usr/bin/batctl if del wlan0

[Install]
WantedBy=multi-user.target
EOT
A$ sudo systemctl daemon-reload && sudo systemctl enable --now lnmesh-mesh
```

### 2.2 Verify

Wait about 30 seconds after the third Pi joins.

```
ALL$ sudo batctl n                 # neighbours: the other two MACs, last-seen < 1 s
ALL$ sudo batctl o                 # originators: both peers, with TQ (0..255)
ALL$ ip -4 addr show bat0          # 10.10.0.x/24
A$   ping -c 3 10.10.0.2 && ping -c 3 10.10.0.3
B$   ping -c 3 10.10.0.3
ALL$ sudo reboot                   # then repeat batctl n: the mesh must survive a reboot
```

**Observed (2026-09-03):** all three Pis joined cell `lnmesh` on 2412 MHz
first try. `batctl n` on each shows both others, last-seen under 1 s.
Direct-link TQ 184 to 236 of 255. Ping RTT over bat0: A to B about 1.7 ms,
A to C and B to C about 7 ms. First A to B ping lost all packets until the
neighbour entry formed; retry was clean. Reboot survival: all three rebooted
together at 19:59; `lnmesh-mesh` active with both neighbours on each within 90 s.

---

## 3. Time (chrony)

Pis have no real-time clock. A syncs from the internet and serves the mesh;
B and C use A as their only source.

```
A$ sudo tee /etc/chrony/conf.d/lnmesh.conf >/dev/null <<'EOT'
allow 10.10.0.0/24
local stratum 10
EOT
A$ sudo systemctl restart chrony
```

```
B$ sudo sed -i 's/^pool /#pool /; s/^server /#server /' /etc/chrony/chrony.conf
B$ sudo tee /etc/chrony/sources.d/lnmesh.sources >/dev/null <<'EOT'
server 10.10.0.1 iburst prefer minpoll 4 maxpoll 6
EOT
B$ sudo tee /etc/chrony/conf.d/lnmesh.conf >/dev/null <<'EOT'
makestep 1 -1
EOT
B$ sudo systemctl restart chrony
```

Repeat the B block on C.

chrony on B and C must not start before A is reachable over the mesh.
Without this, its `iburst` packets are lost while batman-adv is still
discovering neighbours and chrony backs off to a 128 s poll, leaving the
node unsynced for minutes after every boot. The drop-in below waits up to
60 s for A (and starts anyway if A is down), and `minpoll 4 maxpoll 6`
keeps polls at 16 to 64 s:

```
B$ sudo tee /usr/local/sbin/lnmesh-wait-gateway.sh >/dev/null <<'EOT'
#!/bin/bash
for i in $(seq 1 30); do ping -c1 -W1 10.10.0.1 >/dev/null 2>&1 && exit 0; sleep 2; done
exit 0
EOT
B$ sudo chmod 755 /usr/local/sbin/lnmesh-wait-gateway.sh
B$ sudo mkdir -p /etc/systemd/system/chrony.service.d
B$ sudo tee /etc/systemd/system/chrony.service.d/lnmesh.conf >/dev/null <<'EOT'
[Unit]
After=lnmesh-mesh.service
Wants=lnmesh-mesh.service

[Service]
ExecStartPre=/usr/local/sbin/lnmesh-wait-gateway.sh
EOT
B$ sudo systemctl daemon-reload && sudo systemctl restart chrony
```

On A, the same drop-in without the `[Service]` section, so chrony orders
after the mesh unit.

**Verify**

```
B$ chronyc sources                 # exactly one source, 10.10.0.1, marked ^*
B$ chronyc tracking | grep -E 'Reference ID|System time'
A$ chronyc clients                 # lists 10.10.0.2 and 10.10.0.3
```

**Observed (2026-09-03):** B and C each show a single source `^* 10.10.0.1`,
stratum 11, offset under 4 ms within 10 s of restart. `chronyc clients` on A
lists 10.10.0.2 and 10.10.0.3. A serves from its local clock (stratum 10)
until its pool sync completes.
Reboot test 20:02: with chrony merely ordered after the mesh unit, B and C
stayed at `^? reach=0` for over 2 minutes. With the wait script and
minpoll/maxpoll (20:05 reboot), chrony started 40 s after the mesh unit
and showed `^* 10.10.0.1` reach 37 within 60 s, unaided. A now tracks
internet time (stratum 3) and serves B, C.

---

## 4. bitcoind on A (regtest)

### 4.1 Install

```
A$ BTC_VER=29.1
A$ cd /tmp
A$ curl -fsSLO https://bitcoincore.org/bin/bitcoin-core-${BTC_VER}/bitcoin-${BTC_VER}-aarch64-linux-gnu.tar.gz
A$ curl -fsSLO https://bitcoincore.org/bin/bitcoin-core-${BTC_VER}/SHA256SUMS
A$ grep aarch64-linux-gnu SHA256SUMS | sha256sum -c -        # must print OK
A$ tar xzf bitcoin-${BTC_VER}-aarch64-linux-gnu.tar.gz
A$ sudo install -m 755 bitcoin-${BTC_VER}/bin/bitcoind bitcoin-${BTC_VER}/bin/bitcoin-cli /usr/local/bin/
A$ bitcoind --version | head -1
```

### 4.2 User, data directory, credentials

```
A$ sudo useradd -r -m -d /var/lib/bitcoind -s /usr/sbin/nologin bitcoin
A$ curl -fsSL https://raw.githubusercontent.com/bitcoin/bitcoin/v${BTC_VER}/share/rpcauth/rpcauth.py \
     | python3 - lnmesh | tee /tmp/rpcauth.txt
```

`rpcauth.py` prints two lines to keep: `rpcauth=lnmesh:<salt$hash>` for
`bitcoin.conf` and a plaintext password for `lnd.conf` on every Pi. Save
the password in `hosts.env` as `BTC_RPC_PASS`. It never leaves the LAN.

### 4.3 Configuration

```
A$ sudo -u bitcoin tee /var/lib/bitcoind/bitcoin.conf >/dev/null <<'EOT'
regtest=1
server=1
txindex=1
blockfilterindex=1
peerblockfilters=1
listen=1
fallbackfee=0.0001
zmqpubrawblock=tcp://10.10.0.1:28332
zmqpubrawtx=tcp://10.10.0.1:28333

[regtest]
bind=127.0.0.1
bind=10.10.0.1
whitelist=10.10.0.0/24
rpcbind=127.0.0.1
rpcbind=10.10.0.1
rpcallowip=127.0.0.1
rpcallowip=10.10.0.0/24
rpcauth=lnmesh:REPLACE_WITH_RPCAUTH_HASH
EOT
A$ sudo sed -i "s|rpcauth=lnmesh:REPLACE_WITH_RPCAUTH_HASH|$(grep ^rpcauth /tmp/rpcauth.txt)|" /var/lib/bitcoind/bitcoin.conf
```

Regtest RPC listens on 18443 and P2P on 18444. `rpcbind` and `bind` on the
mesh address, plus `blockfilterindex` and `peerblockfilters`, are what
lets B and C read the chain and broadcast through A.

### 4.4 Unit and helpers

```
A$ sudo tee /etc/systemd/system/bitcoind.service >/dev/null <<'EOT'
[Unit]
Description=Bitcoin Core (regtest) for LNMesh
Requires=lnmesh-mesh.service
After=lnmesh-mesh.service

[Service]
User=bitcoin
Group=bitcoin
ExecStart=/usr/local/bin/bitcoind -datadir=/var/lib/bitcoind
Restart=always
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOT
A$ sudo systemctl daemon-reload && sudo systemctl enable --now bitcoind

A$ sudo tee /usr/local/bin/bcli >/dev/null <<'EOT'
#!/bin/bash
exec sudo -u bitcoin /usr/local/bin/bitcoin-cli -datadir=/var/lib/bitcoind "$@"
EOT
A$ sudo tee /usr/local/bin/mine >/dev/null <<'EOT'
#!/bin/bash
# mine N blocks to the address stored by Phase 5.4
exec /usr/local/bin/bcli generatetoaddress "${1:-1}" "$(cat /etc/lnmesh/mine.addr)"
EOT
A$ sudo chmod 755 /usr/local/bin/bcli /usr/local/bin/mine
A$ sudo mkdir -p /etc/lnmesh
```

**Verify**

```
A$ bcli getblockchaininfo | jq '{chain, blocks}'        # regtest, 0
A$ ss -ltnp | grep -E '18443|2833[23]'                  # bound on 10.10.0.1
B$ curl -s --user lnmesh:$BTC_RPC_PASS --data-binary \
     '{"jsonrpc":"1.0","id":"t","method":"getblockcount","params":[]}' \
     http://10.10.0.1:18443/                             # {"result":0,...} over the mesh
```

**Observed (2026-09-03):** Bitcoin Core v29.1.0, checksum OK. bitcoind bound
on 10.10.0.1:18443, 127.0.0.1:18443, ZMQ 28332 and 28333 on 10.10.0.1.
`getblockchaininfo` regtest, 0 blocks. `getblockcount` from B over bat0
returned `{"result":0}` on the first try. Survives reboot.

---

## 5. LND on all three

### 5.1 Install

```
ALL$ LND_VER=v0.19.2-beta   # config deploy: ssh lnmesh-x "sudo bash -s x 10.10.0.N bitcoind|neutrino $BTC_RPC_PASS" < scripts/common/05-lnd-config.sh
ALL$ cd /tmp
ALL$ curl -fsSLO https://github.com/lightningnetwork/lnd/releases/download/${LND_VER}/lnd-linux-arm64-${LND_VER}.tar.gz
ALL$ curl -fsSLO https://github.com/lightningnetwork/lnd/releases/download/${LND_VER}/manifest-${LND_VER}.txt
ALL$ grep linux-arm64 manifest-${LND_VER}.txt | sha256sum -c -     # must print OK
ALL$ tar xzf lnd-linux-arm64-${LND_VER}.tar.gz
ALL$ sudo install -m 755 lnd-linux-arm64-${LND_VER}/lnd lnd-linux-arm64-${LND_VER}/lncli /usr/local/bin/
ALL$ lnd --version
ALL$ sudo useradd -r -m -d /var/lib/lnd -s /usr/sbin/nologin lnd
ALL$ sudo mkdir -p /etc/lnd
```

### 5.2 Configuration

Per-Pi values: `MESH_IP` and `alias`. Everything else identical.

```
A$ sudo tee /etc/lnd/lnd.conf >/dev/null <<'EOT'
[Application Options]
alias=lnmesh-a
listen=10.10.0.1:9735
externalip=10.10.0.1
rpclisten=127.0.0.1:10009
restlisten=127.0.0.1:8080
noseedbackup=true
debuglevel=info

[Bitcoin]
bitcoin.regtest=true
bitcoin.node=bitcoind
bitcoin.defaultremotedelay=1008

[Bitcoind]
bitcoind.rpchost=10.10.0.1:18443
bitcoind.rpcuser=lnmesh
bitcoind.rpcpass=REPLACE_WITH_BTC_RPC_PASS
bitcoind.zmqpubrawblock=tcp://10.10.0.1:28332
bitcoind.zmqpubrawtx=tcp://10.10.0.1:28333
EOT
A$ sudo sed -i "s|REPLACE_WITH_BTC_RPC_PASS|$BTC_RPC_PASS|" /etc/lnd/lnd.conf
A$ sudo chown root:lnd /etc/lnd/lnd.conf && sudo chmod 640 /etc/lnd/lnd.conf
```

On B: `alias=lnmesh-b`, `listen=10.10.0.2:9735`, `externalip=10.10.0.2`, and
instead of the `[Bitcoind]` block:

```
[Bitcoin]
bitcoin.node=neutrino

[neutrino]
neutrino.connect=10.10.0.1:18444
```
On C: `alias=lnmesh-c`, `listen=10.10.0.3:9735`, `externalip=10.10.0.3`.
Only A talks to bitcoind over RPC. B and C run Neutrino (compact block
filters) with A as their only peer, so their best-block view is local and
payments work with A's bitcoind stopped (Demo 5). Every node, including A,
talks to bitcoind over the mesh address.

Notes on the choices:

- `noseedbackup=true` creates the wallet non-interactively. Regtest only.
- Neutrino on B and C was adopted after Demo 5 run 1 showed LND's router
  needs a live `getblockchaininfo` from a bitcoind backend to start a
  payment. It also moves A from "trusted" to "can censor, cannot lie".
- `bitcoin.defaultremotedelay=1008` is the timelock imposed on the
  counterparty; see `PLAN.md` section 5.
- LND on regtest has no fee estimates and falls back to a static rate.
  Demo commands pass `--sat_per_vbyte 1` explicitly.

### 5.3 Unit and wrapper

```
ALL$ sudo tee /usr/local/sbin/lnmesh-wait-bitcoind.sh >/dev/null <<'EOT'
#!/bin/bash
# A: block until bitcoind RPC answers. B, C (Neutrino): wait up to 60 s for
# A's P2P port 18444, then start regardless; an offline node must run
# even when the gateway is down.
until bash -c 'exec 3<>/dev/tcp/10.10.0.1/18443' 2>/dev/null; do sleep 2; done
EOT
ALL$ sudo chmod 755 /usr/local/sbin/lnmesh-wait-bitcoind.sh

ALL$ sudo tee /etc/systemd/system/lnd.service >/dev/null <<'EOT'
[Unit]
Description=LND for LNMesh
Requires=lnmesh-mesh.service
After=lnmesh-mesh.service chrony.service

[Service]
User=lnd
Group=lnd
ExecStartPre=/usr/local/sbin/lnmesh-wait-bitcoind.sh
ExecStart=/usr/local/bin/lnd --lnddir=/var/lib/lnd --configfile=/etc/lnd/lnd.conf
Restart=always
RestartSec=5
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOT

ALL$ sudo tee /usr/local/bin/lncli-mesh >/dev/null <<'EOT'
#!/bin/bash
exec sudo -u lnd /usr/local/bin/lncli --lnddir=/var/lib/lnd --network=regtest "$@"
EOT
ALL$ sudo chmod 755 /usr/local/bin/lncli-mesh
ALL$ sudo systemctl daemon-reload && sudo systemctl enable --now lnd
```

On A only, add `Wants=bitcoind.service` and put `bitcoind.service` in
`After=`. Not `Requires=`: that would stop LND whenever bitcoind stops, and
LND's own health-check exit is clean, so `Restart=always` is needed for it
to come back. `Restart=always` was set after Demo 5 run 1 so
LND always returns.

### 5.4 Mining address and first blocks

```
A$ lncli-mesh newaddress p2tr | jq -r .address | sudo tee /etc/lnmesh/mine.addr
A$ mine 101
```

**Verify**

```
ALL$ lncli-mesh getinfo | jq '{alias, synced_to_chain, block_height, identity_pubkey}'
A$   lncli-mesh walletbalance | jq .confirmed_balance      # 50 BTC from the first mature coinbase
ALL$ sudo reboot; sleep 90; lncli-mesh getinfo | jq .synced_to_chain     # survives reboot
```

Record each node's `identity_pubkey` in `hosts.env` as `PK_A`, `PK_B`,
`PK_C`. The demo scripts use them.

**Observed (2026-09-03):** LND 0.19.2-beta on all three, manifest checksum OK.
Wallets created non-interactively. After `mine 101`: `synced_to_chain` true
at height 101 on A, B, C; A `confirmed_balance` 100 BTC (regtest coinbase).
All three `lnd` units active and synced within 90 s of a cold reboot.
Pubkeys recorded in `hosts.env`: A `0216ff..627f`, B `0273d7..fa51`,
C `03d265..f199`.

---

## 6. Take B and C offline

Final state: B and C have **no Ethernet cable**. Their only link is
`wlan0` in ad-hoc mode carrying batman-adv. Management SSH reaches them
by jumping through A over the mesh. A never routes internet traffic onto
the mesh.

### 6.1 A must not be a router

```
A$ sudo tee /etc/sysctl.d/99-lnmesh-noforward.conf >/dev/null <<'EOT2'
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
EOT
A$ sudo sysctl --system >/dev/null
A$ sysctl net.ipv4.ip_forward                 # = 0
A$ sudo nft list ruleset | grep -i masq       # nothing
```

**Observed (2026-09-03):** `net.ipv4.ip_forward = 0`, `net.ipv6.conf.all.forwarding = 0`
active and persisted in `/etc/sysctl.d/99-lnmesh-noforward.conf`; still 0 after
reboot. `nft list ruleset` on A is empty (0 lines): no masquerade, no forward
chain. Script: `scripts/gateway/06-noforward.sh`.

### 6.2 Laptop reaches B and C through A

Switch the laptop's SSH config for B and C to the mesh addresses via A,
and prove it works while the cables are still in:

```
laptop$ # in ~/.ssh/config, replace the lnmesh-b and lnmesh-c entries:
Host lnmesh-b
  HostName 10.10.0.2
  User mesh-user-b
  ProxyJump lnmesh-a
Host lnmesh-c
  HostName 10.10.0.3
  User mesh-user-c
  ProxyJump lnmesh-a
laptop$ ssh lnmesh-b hostname && ssh lnmesh-c hostname
```

Keep the direct entries as `lnmesh-b-lan` and `lnmesh-c-lan` (LAN addresses,
no ProxyJump) as a fallback while the cables are still in.

**Observed (2026-09-03):** `ssh lnmesh-b` and `ssh lnmesh-c` land via
`$SSH_CONNECTION` source 10.10.0.1, cables still plugged in. From B and C over
the mesh: ping A 0.8 ms and 2.0 ms, bitcoind `getblockcount` 101, `lncli-mesh
getinfo` synced at 101 on all three. After a further reboot of all three at
20:13, ProxyJump access worked within 90 s, both neighbours on each Pi,
chrony on B and C `^* 10.10.0.1`, LND synced. `ssh/config.example` matches.

### 6.3 Pull the cables

Unplug Ethernet from B and C. On each, disable the wired connection so a
cable plugged in by mistake does nothing, and block Bluetooth for good
measure:

```
B$ sudo nmcli con mod "Wired connection 1" connection.autoconnect no
B$ sudo nmcli con down "Wired connection 1" 2>/dev/null || true
B$ sudo rfkill block bluetooth
```

Repeat on C.

**Verify (must fail, not succeed)**

```
B$ ip -br addr                                # only lo, wlan0 (no IPv4), bat0 10.10.0.2
B$ ip route show default                      # empty
B$ curl -m 5 -sI https://example.com; echo "exit=$?"    # exit=6 or 28, never 0
B$ ping -c 1 -W 2 8.8.8.8; echo "exit=$?"     # exit=1 or 2
B$ ping -c 1 192.168.0.1; echo "exit=$?"      # home router unreachable: exit 1 or 2
B$ ping -c 1 10.10.0.1                        # A over the mesh: works
laptop$ ssh lnmesh-b hostname                 # via A: works
```

**Observed (2026-09-03):** cables pulled by hand, `eth0` carrier 0 on both.
After 6.3 on B and C: `Wired connection 1` autoconnect no and down, Bluetooth
soft-blocked. `ip -br addr`: lo, eth0 DOWN, wlan0 (link-local IPv6 only),
bat0 10.10.0.2/3. Default route empty. `curl example.com` exit 6, `ping
8.8.8.8` exit 2, `ping 192.168.0.1` exit 2, `ping 10.10.0.1` exit 0. LND
synced at 101. Rebooted both at 20:26: reachable via ProxyJump 90 s later,
wired still off, both neighbours, chrony `^* 10.10.0.1`, LND synced.
Script: `scripts/offline/06-isolate.sh`.

## 7. Demonstrations

Each demo is one script under `scripts/demo/`. The commands below are what
those scripts run. `$PK_A` etc. come from `hosts.env`.

### Demo 1: Offline funding

B and C receive funds without touching the internet.

```
A$ lncli-mesh connect ${PK_B}@10.10.0.2:9735
A$ lncli-mesh openchannel --node_key $PK_B --local_amt 1000000 --push_amt 400000 --private --sat_per_vbyte 1
A$ mine 6
B$ lncli-mesh channelbalance | jq .local_balance.sat        # 400000, with zero on-chain funds
B$ lncli-mesh walletbalance  | jq .confirmed_balance         # 0

C$ lncli-mesh newaddress p2tr | jq -r .address               # -> $ADDR_C
B$ lncli-mesh newaddress p2tr | jq -r .address               # -> $ADDR_B
A$ lncli-mesh sendcoins --addr $ADDR_C --amt 2000000 --sat_per_vbyte 1
A$ lncli-mesh sendcoins --addr $ADDR_B --amt 2000000 --sat_per_vbyte 1
A$ mine 6
B$ lncli-mesh walletbalance | jq .confirmed_balance          # 2000000
C$ lncli-mesh walletbalance | jq .confirmed_balance          # 2000000
```

**Observed (2026-09-03 20:31, `results/2026-09-03/1-fund.log`):** A opened A-B
(1,000,000 sat, push 400,000) funding txid `8d01d5db..12a1`, seen in A's
mempool, confirmed after `mine 6`, active on both sides within 7 s of the
open. B then had channel balance 400,000 sat with on-chain 0 sat. A paid B
and C 2,000,000 sat each on-chain (`8ab09158..43c1`, `9f9b4631..e4c5`);
both confirmed at height 113 and both wallets showed 2,000,000 confirmed.
Whole demo 22 s wall-clock, dominated by mining and sync.

### Demo 2: Offline channel open

B opens B-C. The funding transaction reaches the chain only through A.

```
B$ lncli-mesh connect ${PK_C}@10.10.0.3:9735
B$ lncli-mesh openchannel --node_key $PK_C --local_amt 1000000 --private --sat_per_vbyte 1
B$ lncli-mesh pendingchannels | jq '.pending_open_channels[].channel.channel_point'
A$ bcli getrawmempool                                         # the funding txid is here, relayed by A
A$ mine 6
B$ lncli-mesh listchannels | jq '.channels[] | {remote_pubkey, active, capacity}'
C$ lncli-mesh listchannels | jq '.channels[] | {remote_pubkey, active, capacity}'

A$ lncli-mesh connect ${PK_C}@10.10.0.3:9735
A$ lncli-mesh openchannel --node_key $PK_C --local_amt 1000000 --push_amt 400000 --private --sat_per_vbyte 1
A$ mine 6
```

**Observed (2026-09-03 20:32, `2-open.log`):** B (no internet) opened B-C
1,000,000 sat: funding txid `83c192cf..8b90`, in A's mempool 1 s after the
command, confirmed at height 114, `listchannels` active on B and C 7 s after
the open. B local 996,530 sat (capacity minus commit fee reserve). A then
opened A-C (`11347494..0e2f`, push 400,000), confirmed by height 125. All
three pairs have a private channel.

### Demo 3: Offline payments

```
C$ lncli-mesh addinvoice --amt 10000 --memo "B to C" | jq -r .payment_request   # -> $INV
B$ lncli-mesh payinvoice --force $INV
A$ lncli-mesh addinvoice --amt 10000 --memo "B to A" | jq -r .payment_request   # -> $INV
B$ lncli-mesh payinvoice --force $INV
B$ lncli-mesh addinvoice --amt 10000 --memo "A to B" | jq -r .payment_request   # -> $INV
A$ lncli-mesh payinvoice --force $INV
B$ lncli-mesh listpayments | jq '.payments[] | {value_sat, status, htlcs: (.htlcs | length)}'
```

**Observed (2026-09-03 20:32, `3-pay.log`):** B->C, B->A, A->B, 10,000 sat
each, all `SUCCEEDED`, zero fee (direct channels). End-to-end latency from
`listpayments` (creation to HTLC resolve): 333 ms, 262 ms, 261 ms. Nothing
touched the chain; height stayed at 125.

### Demo 4: Offline close

Cooperative close of A-B, initiated by B:

```
B$ CP=$(lncli-mesh listchannels | jq -r ".channels[] | select(.remote_pubkey==\"$PK_A\") | .channel_point")
B$ lncli-mesh closechannel --funding_txid ${CP%:*} --output_index ${CP#*:} --sat_per_vbyte 1
A$ mine 1
B$ lncli-mesh closedchannels | jq '.channels[] | {close_type, settled_balance}'
B$ lncli-mesh walletbalance | jq .confirmed_balance
```

Force close of B-C, initiated by B. B's own funds are locked by the delay
C imposed (1008 blocks), then swept:

```
B$ CP=$(lncli-mesh listchannels | jq -r ".channels[] | select(.remote_pubkey==\"$PK_C\") | .channel_point")
B$ lncli-mesh closechannel --force --funding_txid ${CP%:*} --output_index ${CP#*:}
A$ mine 1
B$ lncli-mesh pendingchannels | jq '.pending_force_closing_channels[] | {blocks_til_maturity, limbo_balance}'
A$ mine 1008
B$ lncli-mesh pendingchannels | jq .pending_force_closing_channels        # empty
B$ lncli-mesh walletbalance | jq .confirmed_balance                        # includes swept funds
```

Reopen for the remaining demos:

```
B$ lncli-mesh openchannel --node_key $PK_C --local_amt 1000000 --private --sat_per_vbyte 1
A$ lncli-mesh openchannel --node_key $PK_B --local_amt 1000000 --push_amt 400000 --private --sat_per_vbyte 1
A$ mine 6
```

**Observed (2026-09-03 20:33 and 20:35, `4-close.log`):** Run 1: coop close of
A-B by B, closing txid `fd708e47..1218`, confirmed at 126, B on-chain
999,845 -> 1,399,845 sat (+400,000). Force close of B-C by B, closing txid
`01f59baf..c622` at 127, `blocks_til_maturity` 1008, `maturity_height`
1135, limbo 986,860 sat. After `mine 1008` B's sweep `5c41a917..a77f`
appeared in A's mempool within 30 s and confirmed at 1136; B on-chain
1,399,845 -> 2,386,108 sat (+986,263). **Failure:** the A-B reopen returned
"channels cannot be created before the wallet is fully synced" because A's
wallet was still scanning the 1008 blocks. **Fix:** `open_chan` waits for
`synced_to_chain` and retries up to six times; Demo 4 also waits for all
wallets after the long mine. Run 2 from the start: coop close `5ba558bd..8191`
at 1149 (+400,000), force close `82102701..e16d` at 1150, maturity 2158,
sweep `f836e813..a8e8` at 2159, B 1,785,894 -> 2,782,157 sat. Reopened B-C
(`e6080378..fc32`) and A-B (`9aace155..0eeb`), both active by 2165.

### Demo 5: Baseline replication (pay with no chain at all)

```
A$ sudo systemctl stop bitcoind
C$ lncli-mesh addinvoice --amt 5000 | jq -r .payment_request                 # -> $INV
B$ lncli-mesh payinvoice --force $INV                                        # SUCCEEDED
A$ sudo systemctl start bitcoind
ALL$ sleep 20; lncli-mesh getinfo | jq .synced_to_chain                      # true again
```

**Observed (2026-09-03 20:37, 20:51, 20:54, `5-baseline.log`):** **Run 1 failed**
with the original bitcoind backend on B and C. B's payment stayed
`IN_FLIGHT` with no HTLC attempt; B's log: `Payment ... failed: invalid http
POST response (nil), method: getblockchaininfo`. LND's router calls
`getblockchaininfo` on the bitcoind backend when a payment starts, so with A's
bitcoind down the sender cannot even build a route. 5 min later the
chain-backend health check shut LND down on all three (`Health check: chain
backend failed after 3 calls`), and `Restart=on-failure` did not restart a
clean exit. **Fix:** B and C switched to Neutrino with A as their only peer
(A: `blockfilterindex=1`, `peerblockfilters=1`, P2P bound on 10.10.0.1:18444;
B, C: `bitcoin.node=neutrino`, `neutrino.connect=10.10.0.1:18444`). Best
block is then local. `lnd.service` uses `Restart=always`; A's unit uses
`Wants=bitcoind.service` so a bitcoind restart no longer stops LND. This is
follow-up 1 of `PLAN.md`, now done. **Run 2 (from the start):** bitcoind
stopped 20:54:38; B->C 5,000 sat `SUCCEEDED` in 256 ms; bitcoind started
20:54:43; all three `synced_to_chain` true by 20:54:55. Payments need the
peer link only; the chain backend can be gone.

### Demo 6: Breach response (stretch, regtest only)

C publishes a stale state while B is away. B returns and takes the whole
channel. This deliberately corrupts C's channel database and must never be
done on a network with real value.

```
C$ sudo systemctl stop lnd
C$ sudo cp /var/lib/lnd/data/graph/regtest/channel.db /root/channel.db.stale
C$ sudo systemctl start lnd

# advance the state several times
C$ for i in 1 2 3; do lncli-mesh addinvoice --amt 50000 | jq -r .payment_request; done   # -> pay each from B
B$ lncli-mesh payinvoice --force $INV   # x3

# B goes away, C rewinds and cheats
B$ sudo systemctl stop lnd
C$ sudo systemctl stop lnd
C$ sudo cp /root/channel.db.stale /var/lib/lnd/data/graph/regtest/channel.db
C$ sudo chown lnd:lnd /var/lib/lnd/data/graph/regtest/channel.db
C$ sudo systemctl start lnd
C$ CP=$(lncli-mesh listchannels | jq -r ".channels[] | select(.remote_pubkey==\"$PK_B\") | .channel_point")
C$ lncli-mesh closechannel --force --funding_txid ${CP%:*} --output_index ${CP#*:}
A$ bcli getrawmempool                       # C's stale commitment, relayed by A
A$ mine 1

# B returns, sees the breach through A, and punishes
B$ sudo systemctl start lnd
B$ sleep 30; sudo journalctl -u lnd --since -2min | grep -i -E 'breach|justice'
A$ bcli getrawmempool                       # B's justice transaction
A$ mine 1
B$ lncli-mesh walletbalance | jq .confirmed_balance        # grew by the full channel capacity minus fees
C$ lncli-mesh walletbalance | jq .confirmed_balance        # unchanged: C got nothing
```

B must be stopped *before* C restarts with the stale database. If C
reconnects to B first, LND's data-loss protection on C detects that it is
behind and refuses to broadcast, which is correct behaviour but defeats
the test.

Afterwards, C's channel database is unusable. Reset C (section 8.3).

**Observed (2026-09-03 20:55, `6-breach.log`):** regtest confirmed on all four
daemons. Snapshot of C's `channel.db` taken with B-C at B 986,530 / C
10,000. Three B->C payments of 50,000 advanced the state to B 836,530 / C
160,000 (state #4). B's lnd stopped. C restored the stale db, saw the channel
at its old balance, and force-closed: stale commitment `3df654c9..1796` in
A's mempool, confirmed at height 2166. B's lnd started 20:55:48; 4 s later
its journal read `Remote peer has breached the channel contract ... Revoked
state #4 was broadcast!!!` and `REMOTE PEER IS DOING SOMETHING SKETCHY!!!`,
and it broadcast justice tx `d2f884a7..c29d` through A, confirmed at 2167
(gap 1 block). `closedchannels` on B: `BREACH_CLOSE`, settled 836,530. B
on-chain 1,781,943 -> 2,766,173 sat (+984,230 of the 1,000,000 capacity;
rest is fees); C on-chain unchanged at 2,009,876. Both B and C were on
Neutrino: B detected the breach from compact block filters served by A.
Cleanup: C reset per 8.3 (new identity `03f9d3bf..d14d`, `hosts.env`
updated), A refunded C 2,000,000 (`c93eda41..1ac2`), B-C (`afd18fce..d353`)
and A-C (`279db9ff..aaba`) reopened by 2179. The first run left the old A-C
channel orphaned because the script compared against the new pubkey; it
was force-closed by hand (`fc607294..1a28`, swept by 3189) and the script now
closes it before the reset.

---

## 8. Recovery procedures

### 8.1 A Pi is lost or corrupted

Reflash it (Phase 0.2), then rerun Phases 1 to 5 for that Pi, and Phase 6
if it is B or C. Its LND wallet is new, so its old channels are gone;
counterparties force-close them and the funds return on the regtest chain,
which does not matter. Then rerun the demos from Demo 1.

### 8.2 Reset the regtest chain

Stop lnd everywhere, then bitcoind, wipe both, restart in order:

```
ALL$ sudo systemctl stop lnd
A$   sudo systemctl stop bitcoind
A$   sudo rm -rf /var/lib/bitcoind/regtest
ALL$ sudo rm -rf /var/lib/lnd/data /var/lib/lnd/logs
A$   sudo systemctl start bitcoind
ALL$ sudo systemctl start lnd
```

Then repeat Phase 5.4 and the demos.

### 8.3 Reset one LND node

```
X$ sudo systemctl stop lnd
X$ sudo rm -rf /var/lib/lnd/data /var/lib/lnd/logs
X$ sudo systemctl start lnd
```

The other nodes see its channels as abandoned; force-close them from the
other side and mine.

### 8.4 Mesh drops

```
ALL$ sudo systemctl restart lnmesh-mesh
ALL$ sudo batctl n
```

If a node is missing, check `iw dev wlan0 info` shows `type IBSS` and the
same `ssid` and channel. Two cells with the same SSID but different BSSIDs
never merge; the fixed BSSID in the script prevents that.

### 8.5 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `wlan0` won't enter IBSS | NetworkManager still manages it | Phase 1 unmanaged config, restart NM |
| `rfkill` soft blocked | WiFi country unset | `raspi-config nonint do_wifi_country` |
| bitcoind fails to start | `rpcbind=10.10.0.1` before `bat0` exists | unit `Requires=lnmesh-mesh.service`; check `journalctl -u bitcoind` |
| lnd waits forever | `bitcoind.rpcpass` mismatch or bitcoind not bound to mesh | curl test in Phase 4 Verify from B |
| `openchannel` fails with fee error | No fee estimate on regtest | pass `--sat_per_vbyte 1` |
| Payment fails, `no route` | Peer not connected or channel inactive | `lncli-mesh listpeers`; `listchannels` `active` |
| Payment `IN_FLIGHT` forever, log `getblockchaininfo` error | bitcoind backend unreachable; router needs it to start a payment | Neutrino on offline nodes (Phase 5) |
| lnd exits cleanly after 5 min without chain | chain-backend health check | `Restart=always`; Neutrino keeps the check local |
| `openchannel`: "wallet is fully synced" error | wallet still scanning after a long mine | wait for `synced_to_chain`, retry |
| Clocks drift on B, C | chrony source not A | Phase 3 Verify |
| `chronyc sources` shows `^? reach=0` after boot | chrony polled before mesh found A | Phase 3 drop-in and wait script |

---

## 9. Data to collect for the paper

Collected in `results/2026-09-03/measurements.md` and `link.md`. All of it is in command output already; the
demo scripts should tee it into `results/<date>/`.

| Measurement | Where |
|---|---|
| Mesh link quality between each pair | `batctl o` TQ values, `ping` RTT |
| Mesh throughput | `iperf3 -s` on A, `iperf3 -c 10.10.0.1` on B (install iperf3 in Phase 1 if wanted) |
| Time from broadcast on B to confirmation via A | `openchannel` timestamp vs `mine` timestamp vs `listchannels` active |
| Payment latency | `payinvoice` output, or `lncli-mesh listpayments` `creation_time_ns` vs htlc `resolve_time_ns` |
| Force-close sweep timing | `pendingchannels` `blocks_til_maturity` over time |
| Breach: blocks between stale commit and justice tx | `bcli getblock` heights of the two txids |
| Software versions | section 10 |

---

## 10. Version log

Fill in when the build runs. This table is the authoritative pin list.

| Item | Value |
|---|---|
| Date built | 2026-09-03 (Phase 0 through all six demos in one day) |
| Hardware | 3x Raspberry Pi 5 Model B Rev 1.1, 8 GB, 128 GB microSD |
| OS image | Raspberry Pi OS Lite 64-bit, Debian 13 (trixie) |
| Kernel (`uname -r`) | 6.18.34+rpt-rpi-2712 |
| batctl (`batctl -v`) | debian-2025.0-2; batman-adv kernel module 2025.4; iw 6.9 |
| chrony | 4.6.1 |
| Bitcoin Core | v29.1.0 |
| LND | v0.19.2-beta; A on bitcoind backend, B and C on Neutrino |
| WiFi radio, IBSS support | onboard brcmfmac, IBSS confirmed on all three |
| Mesh channel | 2412 MHz (ch 1), SSID `lnmesh`, BSSID `02:CA:FE:00:00:01` |
| Management IPs | A 192.168.0.130, B 192.168.0.132, C 192.168.0.131 (users mesh-user-a/b/c) |
| Remote delay | 1008 blocks |

---

## 11. File inventory

Files this procedure creates on the Pis, for auditing or for scripting.

| Path | Pis | Purpose |
|---|---|---|
| `/etc/NetworkManager/conf.d/99-lnmesh-unmanaged.conf` | all | keep NM off `wlan0` |
| `/usr/local/sbin/lnmesh-mesh.sh` | all | IBSS + batman-adv bring-up |
| `/etc/systemd/system/lnmesh-mesh.service` | all | runs the above at boot |
| `/etc/chrony/conf.d/lnmesh.conf` | all | server on A, `makestep` on B, C |
| `/etc/chrony/sources.d/lnmesh.sources` | B, C | A as sole time source |
| `/etc/systemd/system/chrony.service.d/lnmesh.conf` | all | chrony after mesh; on B, C waits for A |
| `/usr/local/sbin/lnmesh-wait-gateway.sh` | B, C | bounded wait for A before chrony starts |
| `/var/lib/bitcoind/bitcoin.conf` | A | regtest, RPC and ZMQ on the mesh |
| `/etc/systemd/system/bitcoind.service` | A | |
| `/usr/local/bin/bcli`, `/usr/local/bin/mine` | A | wrappers |
| `/etc/lnmesh/mine.addr` | A | coinbase address (A's lnd wallet) |
| `/etc/lnd/lnd.conf` | all | bitcoind backend on A, Neutrino on B, C |
| `scripts/gateway/07-blockfilters.sh` (repo) | A | enables filters and P2P for Neutrino |
| `/usr/local/sbin/lnmesh-wait-bitcoind.sh` | all | gate lnd on A's RPC port |
| `/etc/systemd/system/lnd.service` | all | |
| `/etc/sysctl.d/99-lnmesh-noforward.conf` | A | no forwarding onto the mesh (Phase 6.1) |
| `/usr/local/bin/lncli-mesh` | all | wrapper |
| `/var/lib/lnd/data/graph/regtest/channel.db` | all | channel state; copied in Demo 6 |
