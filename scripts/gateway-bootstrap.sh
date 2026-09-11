#!/usr/bin/env bash
# Gateway-side enrollment driver.
set -euo pipefail
IFS=$'\n\t'

die() { echo "gateway-bootstrap: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "must run as root"
[[ $# -eq 2 && "$1" == "--expect" ]] || die "usage: $0 --expect 1..7"
[[ "$2" =~ ^[1-7]$ ]] || die "--expect must be between 1 and 7"
readonly EXPECT="$2"
readonly ENROLLER="${LN_MESH_ENROLLER:-/usr/local/lib/lnmesh/enroll-leaf}"

[[ -x "$ENROLLER" ]] || die "missing installed enrollment helper: $ENROLLER"
exec "$ENROLLER" --expect "$EXPECT"
