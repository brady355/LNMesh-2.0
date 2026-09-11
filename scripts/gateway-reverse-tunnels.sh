#!/usr/bin/env bash
# Maintain gateway-initiated reverse tunnels from leaves back to gateway Core.
set -euo pipefail
IFS=$'\n\t'

readonly TUNNELS_FILE="${LN_MESH_TUNNELS_FILE:-/etc/lnmesh/tunnels.tsv}"
readonly CORE_TARGET="${LN_MESH_CORE_TARGET:-127.0.0.1:18443}"
die() { echo "gateway-reverse-tunnels: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "must run as root"
command -v autossh >/dev/null || die "autossh is required"
[[ -r "$TUNNELS_FILE" ]] || die "missing tunnel inventory $TUNNELS_FILE"
[[ $# -eq 1 ]] || die "usage: $0 NODE_NAME"
readonly REQUESTED_NODE="$1"

# Format: node-name<TAB>mesh-ip<TAB>leaf-loopback-rpc-port<TAB>identity-file
# The port is bound to loopback on the leaf; GatewayPorts is never enabled.
line="$(awk -F '\t' -v node="$REQUESTED_NODE" '$1 == node {print; exit}' "$TUNNELS_FILE")"
[[ -n "$line" ]] || die "no tunnel inventory entry for $REQUESTED_NODE"
IFS=$'\t' read -r node ip port key <<< "$line"
[[ "$ip" =~ ^10\.77\.0\.[2-8]$ ]] || die "invalid mesh address for $node"
[[ "$port" =~ ^[0-9]+$ ]] || die "invalid RPC port for $node"
[[ -r "$key" ]] || die "unreadable tunnel key for $node"
exec autossh -M 0 -N \
  -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/lnmesh/known_hosts -i "$key" \
  -R "127.0.0.1:${port}:${CORE_TARGET}" "lnmesh-tunnel@${ip}"
