#!/usr/bin/env bash
# Freeze publication before a pruned Core discards blocks needed by a leaf.
set -euo pipefail
IFS=$'\n\t'

readonly INVENTORY="${LN_MESH_RETENTION_INVENTORY:-/etc/lnmesh/retention.tsv}"
readonly OUTAGE_MARKER="${LN_MESH_OUTAGE_MARKER:-/var/lib/lnmesh/manual-outage}"
readonly INTERLOCK_MARKER="${LN_MESH_INTERLOCK_MARKER:-/var/lib/lnmesh/retention-interlock}"
readonly WARN_BLOCKS="${LN_MESH_MIN_RETENTION_WARN_BLOCKS:-8064}"
readonly FREEZE_BLOCKS="${LN_MESH_MIN_RETENTION_FREEZE_BLOCKS:-4032}"
readonly LEAF_STATUS="${LN_MESH_LEAF_STATUS:-/usr/local/lib/lnmesh/leaf-status}"
die() { echo "retention-guard: $*" >&2; exit 1; }
command -v bitcoin-cli >/dev/null || die "bitcoin-cli is required"
[[ -x "$LEAF_STATUS" ]] || die "missing leaf status helper: $LEAF_STATUS"
bitcoin=(bitcoin-cli -conf=/etc/lnmesh/bitcoin.conf -datadir=/var/lib/bitcoin)

pruneheight="$("${bitcoin[@]}" getblockchaininfo | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pruneheight", 0))')"
[[ "$pruneheight" =~ ^[0-9]+$ ]] || die "could not determine prune height"
if (( pruneheight == 0 )); then
  rm -f -- "$INTERLOCK_MARKER"
  if [[ ! -e "$OUTAGE_MARKER" ]]; then "${bitcoin[@]}" setnetworkactive true >/dev/null; fi
  exit 0
fi
minimum_margin=999999999

# Format: node-name<TAB>last-known-cln-height<TAB>rescan-height
while IFS=$'\t' read -r node known_height rescan_height; do
  [[ -z "$node" || "$node" == \#* ]] && continue
  [[ "$known_height" =~ ^[0-9]+$ && "$rescan_height" =~ ^[0-9]+$ ]] || die "invalid retention record for $node"
  live_height="$($LEAF_STATUS "$node" height 2>/dev/null || printf '%s' "$known_height")"
  [[ "$live_height" =~ ^[0-9]+$ ]] || live_height="$known_height"
  margin=$(( (live_height - rescan_height) - pruneheight ))
  (( margin < minimum_margin )) && minimum_margin="$margin"
done < "$INVENTORY"

if (( minimum_margin < FREEZE_BLOCKS )); then
  echo "retention-guard: freezing P2P; margin=${minimum_margin}" >&2
  touch "$INTERLOCK_MARKER"
  chmod 0600 "$INTERLOCK_MARKER"
  [[ -e "$OUTAGE_MARKER" ]] || "${bitcoin[@]}" setnetworkactive false >/dev/null
  exit 2
fi
rm -f -- "$INTERLOCK_MARKER"
if (( minimum_margin < WARN_BLOCKS )); then
  echo "retention-guard: warning; margin=${minimum_margin}" >&2
fi
if [[ ! -e "$OUTAGE_MARKER" ]]; then
  "${bitcoin[@]}" setnetworkactive true >/dev/null
fi
