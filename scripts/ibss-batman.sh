#!/usr/bin/env bash
# Bring up the locked IBSS + BATMAN_IV underlay on the existing wlan0.
set -euo pipefail
IFS=$'\n\t'

readonly CONFIG_FILE="${LN_MESH_IBSS_CONFIG:-/etc/lnmesh/ibss.env}"

die() { echo "ibss-batman: $*" >&2; exit 1; }
require_root() { [[ ${EUID} -eq 0 ]] || die "must run as root"; }
require() { command -v "$1" >/dev/null || die "missing required command: $1"; }

load_config() {
  [[ -r "$CONFIG_FILE" ]] || die "missing configuration $CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  : "${IBSS_INTERFACE:?}" "${IBSS_SSID:?}" "${IBSS_BSSID:?}" "${IBSS_FREQUENCY_MHZ:?}"
  : "${IBSS_COUNTRY:?}" "${BATMAN_INTERFACE:?}"
  [[ "$IBSS_BSSID" =~ ^02(:[0-9A-Fa-f]{2}){5}$ ]] || die "BSSID must be locally administered (02:...)"
  [[ "$IBSS_FREQUENCY_MHZ" == "2412" ]] || die "only the locked channel-1 default is supported"
}

stop_wifi_managers() {
  if command -v nmcli >/dev/null; then nmcli device set "$IBSS_INTERFACE" managed no || true; fi
  systemctl stop "wpa_supplicant@${IBSS_INTERFACE}.service" 2>/dev/null || true
}

start() {
  require_root; load_config
  for command in iw ip modprobe batctl; do require "$command"; done
  iw dev "$IBSS_INTERFACE" info >/dev/null || die "wireless interface $IBSS_INTERFACE not found"
  stop_wifi_managers
  iw reg set "$IBSS_COUNTRY"
  modprobe batman-adv
  ip link set dev "$IBSS_INTERFACE" down
  # There is intentionally no virtual interface or infrastructure-mode fallback.
  iw dev "$IBSS_INTERFACE" set type ibss
  ip addr flush dev "$IBSS_INTERFACE"
  ip link set dev "$IBSS_INTERFACE" up
  iw dev "$IBSS_INTERFACE" ibss join "$IBSS_SSID" "$IBSS_FREQUENCY_MHZ" fixed-freq "$IBSS_BSSID"
  ip link show "$BATMAN_INTERFACE" >/dev/null 2>&1 || ip link add name "$BATMAN_INTERFACE" type batadv
  echo BATMAN_IV > "/sys/class/net/${BATMAN_INTERFACE}/mesh/routing_algo"
  batctl meshif "$BATMAN_INTERFACE" interface add "$IBSS_INTERFACE"
  ip link set dev "$BATMAN_INTERFACE" mtu 1468 up
  if [[ -n "${LN_MESH_NODE_ADDRESS:-}" ]]; then
    ip addr replace "$LN_MESH_NODE_ADDRESS" dev "$BATMAN_INTERFACE"
  fi
  # Leaves must never acquire a default route via the mesh.
  if [[ "${LN_MESH_ROLE:-leaf}" == "leaf" ]]; then
    ip route del default dev "$BATMAN_INTERFACE" 2>/dev/null || true
  fi
}

stop() {
  require_root; load_config
  ip link set dev "$BATMAN_INTERFACE" down 2>/dev/null || true
  ip link del dev "$BATMAN_INTERFACE" type batadv 2>/dev/null || true
  iw dev "$IBSS_INTERFACE" ibss leave 2>/dev/null || true
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  *) die "usage: $0 start|stop" ;;
esac
