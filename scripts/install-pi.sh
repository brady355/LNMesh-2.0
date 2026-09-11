#!/usr/bin/env bash
# Idempotent Raspberry Pi 5 installer for an LNMesh gateway or leaf.
set -euo pipefail
IFS=$'\n\t'

readonly INSTALLER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE_DIR="$(cd -- "$INSTALLER_DIR/.." && pwd)"
readonly BITCOIN_VERSION="31.1"
readonly BITCOIN_ARCHIVE="bitcoin-31.1-aarch64-linux-gnu.tar.gz"
readonly BITCOIN_SHA256="dcf1873f2208ba4f962f3398d47e154c39c0084be8f4553e05c940d0ace3d004"
readonly CLN_VERSION="26.06.7"
readonly CLN_ARCHIVE="clightning-v26.06.7-Ubuntu-24.04-arm64.tar.xz"
readonly CLN_SHA256="322c8a3093c97fdad90fe289687dd5b38214845c81bd0b4a393abb7f7217217e"

role="${1:-}"
[[ $# -gt 0 ]] && shift
network="regtest"
country=""
mesh_name="lnmesh-lab"
bootstrap_key=""
start_services=1
allow_unsupported=0

usage() {
  cat <<EOF
Usage: sudo bash ./install-${role}.sh --country CC [options]

  --network regtest|testnet4|bitcoin  Fixed network for this Pi (default: regtest)
  --mesh-name NAME                    Shared deployment name (default: lnmesh-lab)
  --bootstrap-key FILE                Gateway public enrollment key (leaf only)
  --no-start                          Install without starting services
  --allow-unsupported-host            Skip Pi 5 / Trixie checks (development only)
EOF
}

die() { echo "lnmesh installer: $*" >&2; exit 1; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }
need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) need_value "$@"; network="$2"; shift 2 ;;
    --country) need_value "$@"; country="${2^^}"; shift 2 ;;
    --mesh-name) need_value "$@"; mesh_name="$2"; shift 2 ;;
    --bootstrap-key) need_value "$@"; bootstrap_key="$2"; shift 2 ;;
    --no-start) start_services=0; shift ;;
    --allow-unsupported-host) allow_unsupported=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$role" == "gateway" || "$role" == "leaf" ]] || die "role must be gateway or leaf"
[[ "$network" == "regtest" || "$network" == "testnet4" || "$network" == "bitcoin" ]] || die "invalid network"
[[ "$country" =~ ^[A-Z]{2}$ ]] || die "--country must be a two-letter regulatory country code"
[[ "$mesh_name" =~ ^[A-Za-z0-9._-]{1,24}$ ]] || die "--mesh-name must contain 1-24 letters, digits, dot, underscore, or dash"
[[ ${EUID} -eq 0 ]] || die "run with sudo"
exec 9>/run/lock/lnmesh-installer.lock
flock -n 9 || die "another LNMesh installer is running"

if (( allow_unsupported == 0 )); then
  [[ "$(uname -m)" == "aarch64" ]] || die "requires 64-bit ARM Raspberry Pi OS"
  grep -qi 'Raspberry Pi 5' /proc/device-tree/model 2>/dev/null || die "requires Raspberry Pi 5; use --allow-unsupported-host only for development"
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${VERSION_CODENAME:-}" == "trixie" ]] || die "requires Raspberry Pi OS Trixie"
  [[ "$(uname -r)" == 6.18* ]] || die "requires the validated Trixie 6.18 kernel"
fi
if [[ "$role" == "gateway" && "$start_services" -eq 1 ]]; then
  ip route show default | grep -Eq ' dev eth0([[:space:]]|$)' || die "gateway needs an Ethernet default route before wlan0 is moved into IBSS mode"
fi

if [[ -s /var/lib/lnmesh/network ]]; then
  installed_network="$(tr -d '[:space:]' < /var/lib/lnmesh/network)"
  [[ "$installed_network" == "$network" ]] || die "this Pi is initialized for $installed_network and must not be changed to $network"
fi
for setting in role mesh-name country; do
  setting_file="/var/lib/lnmesh/install-$setting"
  [[ -s "$setting_file" ]] || continue
  installed_value="$(tr -d '\r\n' < "$setting_file")"
  case "$setting" in
    role) requested_value="$role" ;;
    mesh-name) requested_value="$mesh_name" ;;
    country) requested_value="$country" ;;
  esac
  [[ "$installed_value" == "$requested_value" ]] || die "this Pi is already installed with $setting=$installed_value"
done

mesh_hash="$(printf '%s' "$mesh_name" | sha256sum | cut -c1-10)"
bssid="02:${mesh_hash:0:2}:${mesh_hash:2:2}:${mesh_hash:4:2}:${mesh_hash:6:2}:${mesh_hash:8:2}"
ssid="LNMesh-${mesh_name}"
cache_dir="/var/cache/lnmesh"

fetch_verified() {
  local url="$1" expected="$2" destination="$3" partial="${destination}.part"
  if [[ -s "$destination" ]] && printf '%s  %s\n' "$expected" "$destination" | sha256sum --check --status; then
    return
  fi
  curl --fail --location --retry 3 --connect-timeout 15 --output "$partial" "$url"
  printf '%s  %s\n' "$expected" "$partial" | sha256sum --check --status || die "checksum verification failed for $(basename "$destination")"
  mv -f "$partial" "$destination"
}

install_bitcoin() {
  local archive="$cache_dir/$BITCOIN_ARCHIVE" unpack
  if command -v bitcoin-cli >/dev/null && bitcoin-cli --version | head -n1 | grep -Fq "$BITCOIN_VERSION"; then
    if [[ "$role" == "leaf" ]] || { command -v bitcoind >/dev/null && bitcoind --version | head -n1 | grep -Fq "$BITCOIN_VERSION"; }; then
      return
    fi
  fi
  fetch_verified "https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/${BITCOIN_ARCHIVE}" "$BITCOIN_SHA256" "$archive"
  unpack="$(mktemp -d /tmp/lnmesh-bitcoin.XXXXXX)"
  tar -xzf "$archive" -C "$unpack"
  install -m 0755 "$unpack/bitcoin-${BITCOIN_VERSION}/bin/bitcoin-cli" /usr/local/bin/bitcoin-cli
  if [[ "$role" == "gateway" ]]; then
    install -m 0755 "$unpack/bitcoin-${BITCOIN_VERSION}/bin/bitcoind" /usr/local/bin/bitcoind
    install -m 0755 "$unpack/bitcoin-${BITCOIN_VERSION}/bin/bitcoin-tx" /usr/local/bin/bitcoin-tx
    install -m 0755 "$unpack/bitcoin-${BITCOIN_VERSION}/bin/bitcoin-util" /usr/local/bin/bitcoin-util
  fi
  rm -rf -- "$unpack"
}

install_cln() {
  local archive="$cache_dir/$CLN_ARCHIVE"
  if command -v lightningd >/dev/null && lightningd --version | grep -Fq "$CLN_VERSION"; then return; fi
  fetch_verified "https://github.com/ElementsProject/lightning/releases/download/v${CLN_VERSION}/${CLN_ARCHIVE}" "$CLN_SHA256" "$archive"
  tar -xJf "$archive" -C /usr/local --strip-components=2
}

step 1 "Installing operating-system dependencies"
export DEBIAN_FRONTEND=noninteractive
if ! find /var/lib/apt/lists -type f -mmin -360 -print -quit 2>/dev/null | grep -q .; then
  apt-get update -qq
fi
packages=(ca-certificates curl xz-utils python3 batctl iw nftables iproute2 openssh-server autossh avahi-daemon libnss-mdns chrony age jq zram-tools openssl)
if [[ "$role" == "leaf" ]]; then
  packages+=(libsqlite3-0 libgmp10 libpq5 libsodium23)
fi
apt-get install -y -qq --no-install-recommends "${packages[@]}"

step 2 "Downloading and verifying pinned ARM64 binaries"
install -d -m 0755 "$cache_dir"
install_bitcoin
if [[ "$role" == "leaf" ]]; then install_cln; fi

step 3 "Installing LNMesh control files"
getent group lnmesh >/dev/null || groupadd --system lnmesh
id -u lnmesh >/dev/null 2>&1 || useradd --system --gid lnmesh --home-dir /var/lib/lnmesh --shell /usr/sbin/nologin lnmesh
install -d -m 2770 -o root -g lnmesh /var/lib/lnmesh
install -d -m 0755 /usr/local/lib/lnmesh /usr/local/lib/lnmesh/python/lnmeshctl /etc/lnmesh /etc/systemd/system
install -d -m 0755 /etc/NetworkManager/conf.d
for file in "$SOURCE_DIR"/lnmeshctl/*.py; do install -m 0644 "$file" /usr/local/lib/lnmesh/python/lnmeshctl/; done
for file in "$SOURCE_DIR"/scripts/*.sh; do install -m 0755 "$file" "/usr/local/lib/lnmesh/$(basename "$file")"; done
install -m 0755 "$SOURCE_DIR/scripts/enroll-leaf" /usr/local/lib/lnmesh/enroll-leaf
install -m 0755 "$SOURCE_DIR/scripts/leaf-status" /usr/local/lib/lnmesh/leaf-status
install -m 0755 "$SOURCE_DIR/packaging/lnmeshctl" /usr/local/bin/lnmeshctl
install -m 0755 "$SOURCE_DIR/packaging/lnmesh-lifecycle-worker" /usr/local/bin/lnmesh-lifecycle-worker
for file in "$SOURCE_DIR"/systemd/*; do install -m 0644 "$file" "/etc/systemd/system/$(basename "$file")"; done
printf '%s\n' "$network" > /var/lib/lnmesh/network
printf '%s\n' "$role" > /var/lib/lnmesh/install-role
printf '%s\n' "$mesh_name" > /var/lib/lnmesh/install-mesh-name
printf '%s\n' "$country" > /var/lib/lnmesh/install-country
chown root:lnmesh /var/lib/lnmesh/network
chown root:lnmesh /var/lib/lnmesh/install-role /var/lib/lnmesh/install-mesh-name /var/lib/lnmesh/install-country
chmod 0640 /var/lib/lnmesh/network /var/lib/lnmesh/install-role /var/lib/lnmesh/install-mesh-name /var/lib/lnmesh/install-country

core_port=8332
[[ "$network" == "regtest" ]] && core_port=18443
[[ "$network" == "testnet4" ]] && core_port=48332
node_address_line='LN_MESH_NODE_ADDRESS='
if [[ "$role" == "gateway" ]]; then
  node_address_line='LN_MESH_NODE_ADDRESS=10.77.0.1/24'
elif [[ -s /var/lib/lnmesh/enrolled && -s /etc/lnmesh/ibss.env ]]; then
  node_address_line="$(grep '^LN_MESH_NODE_ADDRESS=' /etc/lnmesh/ibss.env || true)"
fi
printf '%s\n' \
  "LN_MESH_ROLE=$role" \
  "LN_MESH_NETWORK=$network" \
  'LN_MESH_STATE_DIR=/var/lib/lnmesh' \
  'LN_MESH_GATEWAY_IP=10.77.0.1' \
  'LN_MESH_MESH_CIDR=10.77.0.0/24' \
  'LN_MESH_MAINNET_CHANNEL_CAP_SAT=100000' \
  'LN_MESH_MIN_RETENTION_WARN_BLOCKS=8064' \
  'LN_MESH_MIN_RETENTION_FREEZE_BLOCKS=4032' \
  "LN_MESH_CORE_TARGET=127.0.0.1:${core_port}" > /etc/lnmesh/lnmesh.env
chown root:lnmesh /etc/lnmesh/lnmesh.env
chmod 0640 /etc/lnmesh/lnmesh.env
printf '%s\n' \
  'IBSS_INTERFACE=wlan0' \
  "IBSS_SSID=$ssid" \
  "IBSS_BSSID=$bssid" \
  'IBSS_FREQUENCY_MHZ=2412' \
  "IBSS_COUNTRY=$country" \
  'BATMAN_INTERFACE=bat0' \
  "LN_MESH_ROLE=$role" \
  "$node_address_line" \
  'LN_MESH_GATEWAY_ADDRESS=10.77.0.1' > /etc/lnmesh/ibss.env
chmod 0644 /etc/lnmesh/ibss.env
printf '%s\n' '[keyfile]' 'unmanaged-devices=interface-name:wlan0' > /etc/NetworkManager/conf.d/90-lnmesh-unmanaged.conf
install -d -m 0755 /etc/systemd/journald.conf.d /etc/chrony/conf.d
printf '%s\n' '[Journal]' 'SystemMaxUse=200M' 'RuntimeMaxUse=64M' 'MaxRetentionSec=14day' > /etc/systemd/journald.conf.d/90-lnmesh.conf
if [[ "$role" == "gateway" ]]; then
  printf '%s\n' 'allow 10.77.0.0/24' 'local stratum 10' > /etc/chrony/conf.d/lnmesh.conf
else
  printf '%s\n' 'server 10.77.0.1 iburst prefer' > /etc/chrony/conf.d/lnmesh.conf
fi
systemctl disable --now wpa_supplicant.service "wpa_supplicant@wlan0.service" >/dev/null 2>&1 || true
systemctl mask wpa_supplicant.service "wpa_supplicant@wlan0.service" >/dev/null 2>&1 || true

if [[ "$role" == "gateway" ]]; then
  step 4 "Configuring the Bitcoin gateway"
  getent group bitcoin >/dev/null || groupadd --system bitcoin
  id -u bitcoin >/dev/null 2>&1 || useradd --system --gid bitcoin --home-dir /var/lib/bitcoin --shell /usr/sbin/nologin bitcoin
  install -d -m 0750 -o bitcoin -g bitcoin /var/lib/bitcoin
  network_line=""
  wallet_line='disablewallet=1'
  [[ "$network" == "regtest" ]] && { network_line='regtest=1'; wallet_line='disablewallet=0'; }
  [[ "$network" == "testnet4" ]] && network_line='testnet4=1'
  existing_rpc_lines=""
  if [[ -s /etc/lnmesh/bitcoin.conf ]]; then
    existing_rpc_lines="$(grep -E '^(rpcauth|rpcwhitelist)=' /etc/lnmesh/bitcoin.conf || true)"
  fi
  printf '%s\n' \
    "$network_line" 'server=1' 'daemon=0' 'prune=200000' "$wallet_line" \
    'txindex=0' 'blockfilterindex=0' 'blocksonly=0' 'persistmempool=1' \
    'rpcbind=127.0.0.1' 'rpcallowip=127.0.0.1' 'rpcwhitelistdefault=0' 'networkactive=0' > /etc/lnmesh/bitcoin.conf
  if [[ -n "$existing_rpc_lines" ]]; then printf '%s\n' "$existing_rpc_lines" >> /etc/lnmesh/bitcoin.conf; fi
  chown root:bitcoin /etc/lnmesh/bitcoin.conf
  chmod 0640 /etc/lnmesh/bitcoin.conf
  [[ -e /etc/lnmesh/inventory.tsv ]] || install -m 0600 /dev/null /etc/lnmesh/inventory.tsv
  [[ -e /etc/lnmesh/tunnels.tsv ]] || install -m 0600 /dev/null /etc/lnmesh/tunnels.tsv
  [[ -e /etc/lnmesh/retention.tsv ]] || install -m 0640 -o root -g lnmesh /dev/null /etc/lnmesh/retention.tsv
  install -d -m 0700 /etc/lnmesh/keys /var/lib/lnmesh/export
  if [[ ! -s /etc/lnmesh/keys/bootstrap ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "lnmesh-bootstrap-$mesh_name" -f /etc/lnmesh/keys/bootstrap
  fi
  chmod 0600 /etc/lnmesh/keys/bootstrap
  install -m 0644 /etc/lnmesh/keys/bootstrap.pub /var/lib/lnmesh/export/bootstrap_authorized_key.pub
  chown -R lnmesh:lnmesh /var/lib/lnmesh/export
else
  step 4 "Configuring the isolated Lightning leaf"
  getent group lightning >/dev/null || groupadd --system lightning
  id -u lightning >/dev/null 2>&1 || useradd --system --gid lightning --home-dir /var/lib/lightning --shell /usr/sbin/nologin lightning
  getent group lnmesh-tunnel >/dev/null || groupadd --system lnmesh-tunnel
  id -u lnmesh-tunnel >/dev/null 2>&1 || useradd --system --create-home --gid lnmesh-tunnel --home-dir /var/lib/lnmesh-tunnel --shell /bin/bash lnmesh-tunnel
  if passwd --status lnmesh-tunnel | awk '{exit $2 == "L" ? 0 : 1}'; then
    tunnel_password="$(openssl rand -base64 48)"
    tunnel_password_hash="$(printf '%s' "$tunnel_password" | openssl passwd -6 -stdin)"
    usermod --password "$tunnel_password_hash" lnmesh-tunnel
    unset tunnel_password
    unset tunnel_password_hash
  fi
  install -d -m 0750 -o lightning -g lightning /var/lib/lightning
  install -d -m 0700 -o lnmesh-tunnel -g lnmesh-tunnel /var/lib/lnmesh-tunnel/.ssh
  install -d -m 0755 /etc/ssh/sshd_config.d
  printf '%s\n' \
    'Match User lnmesh-tunnel' \
    '  PasswordAuthentication no' \
    '  KbdInteractiveAuthentication no' \
    '  X11Forwarding no' \
    '  AllowAgentForwarding no' \
    '  AllowTcpForwarding remote' \
    '  PermitTTY no' > /etc/ssh/sshd_config.d/90-lnmesh.conf
  chmod 0644 /etc/ssh/sshd_config.d/90-lnmesh.conf
  sshd -t
  if [[ ! -s /var/lib/lnmesh/enrolled ]]; then
    [[ -n "$bootstrap_key" ]] || bootstrap_key="$SOURCE_DIR/config/deployment-bootstrap.pub"
    [[ -s "$bootstrap_key" ]] || die "leaf needs --bootstrap-key FILE copied from the gateway's /var/lib/lnmesh/export/bootstrap_authorized_key.pub"
    grep -q '^ssh-ed25519 ' "$bootstrap_key" || die "bootstrap key must be an ssh-ed25519 public key"
    install -m 0644 "$bootstrap_key" /etc/lnmesh/bootstrap_authorized_key
    install -d -m 0700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
    key_material="$(cat "$bootstrap_key")"
    if ! grep -Fq "$key_material" /root/.ssh/authorized_keys; then
      printf 'restrict,command="/usr/local/lib/lnmesh/bootstrap-shell.sh" %s\n' "$key_material" >> /root/.ssh/authorized_keys
    fi
  fi
  install -m 0644 "$SOURCE_DIR/systemd/lnmesh-enrollment.service" /etc/systemd/system/lnmesh-enrollment.service
fi

step 5 "Enabling services"
systemctl daemon-reload
systemctl enable lnmesh-ibss.service lnmesh-isolation.service >/dev/null
if [[ "$role" == "gateway" ]]; then
  systemctl enable bitcoind.service lnmesh-retention-guard.timer lnmesh-lifecycle-worker.timer >/dev/null
else
  systemctl enable ssh.service avahi-daemon.service lnmesh-enrollment.service >/dev/null
  if [[ -s /var/lib/lnmesh/enrolled ]]; then
    systemctl disable lnmesh-enrollment.service >/dev/null 2>&1 || true
    systemctl enable lightningd.service >/dev/null
  else
    systemctl disable lightningd.service >/dev/null 2>&1 || true
  fi
fi
if (( start_services == 1 )); then
  if [[ "$role" == "leaf" ]]; then
    echo "Switching wlan0 into the mesh now; a Wi-Fi SSH session may disconnect."
  fi
  systemctl restart lnmesh-ibss.service
  systemctl restart lnmesh-isolation.service
  systemctl restart chrony.service systemd-journald.service
  if [[ "$role" == "gateway" ]]; then
    systemctl restart bitcoind.service
    systemctl start lnmesh-retention-guard.timer lnmesh-lifecycle-worker.timer
  else
    systemctl restart ssh.service avahi-daemon.service
    if [[ -s /var/lib/lnmesh/enrolled ]]; then
      systemctl restart lightningd.service
    else
      systemctl restart lnmesh-enrollment.service
    fi
  fi
fi

step 6 "Installation complete"
echo "Role: $role   Network: $network   SSID: $ssid   BSSID: $bssid"
if [[ "$role" == "gateway" ]]; then
  echo "Copy this public file to every leaf before running its installer:"
  echo "  /var/lib/lnmesh/export/bootstrap_authorized_key.pub"
  echo "After installing the leaves, run: sudo lnmeshctl bootstrap --expect N"
else
  echo "Leaf is advertising enrollment and Lightning remains stopped until bootstrap."
fi
