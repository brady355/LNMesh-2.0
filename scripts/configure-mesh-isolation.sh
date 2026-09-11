#!/usr/bin/env bash
# Install the gateway/leaf forwarding rules that keep leaves off the Internet.
set -euo pipefail
IFS=$'\n\t'

readonly ROLE="${LN_MESH_ROLE:?set LN_MESH_ROLE to gateway or leaf}"
readonly BATMAN_INTERFACE="${BATMAN_INTERFACE:-bat0}"
readonly WAN_INTERFACE="${LN_MESH_WAN_INTERFACE:-eth0}"
die() { echo "configure-mesh-isolation: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "must run as root"
[[ "$ROLE" == "gateway" || "$ROLE" == "leaf" ]] || die "invalid role: $ROLE"
command -v nft >/dev/null || die "nft is required"

# A separate table prevents accidental modification of distribution firewall
# policy.  The forward hook explicitly drops bat0<->WAN in either direction.
nft delete table inet lnmesh 2>/dev/null || true
nft -f - <<EOF
table inet lnmesh {
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "${BATMAN_INTERFACE}" oifname "${WAN_INTERFACE}" counter drop
    iifname "${WAN_INTERFACE}" oifname "${BATMAN_INTERFACE}" counter drop
  }
}
EOF

if [[ "$ROLE" == "leaf" ]]; then
  # No default route is permitted on any leaf, including a stale route left by
  # a DHCP client.  The mesh remains usable through its connected /24 route.
  ip route del default 2>/dev/null || true
fi
