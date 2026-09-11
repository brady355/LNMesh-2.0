#!/usr/bin/env bash
set -euo pipefail
readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/env bash "$ROOT_DIR/scripts/install-pi.sh" gateway "$@"
