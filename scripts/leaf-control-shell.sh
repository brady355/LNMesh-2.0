#!/usr/bin/env bash
# Allowlist for the per-node gateway control key.  It never accepts arbitrary
# shell commands, passwords, PSBTs, or private material as command arguments.
set -euo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
case "${SSH_ORIGINAL_COMMAND:-}" in
  start)
    systemctl enable --now lightningd.service >/dev/null
    echo ready
    ;;
  status)
    systemctl is-active lightningd.service
    ;;
  height)
    runuser -u lightning -- lightning-cli --lightning-dir=/var/lib/lightning getinfo | jq -er '.blockheight'
    ;;
  getinfo)
    runuser -u lightning -- lightning-cli --lightning-dir=/var/lib/lightning getinfo
    ;;
  rpc)
    export PYTHONPATH=/usr/local/lib/lnmesh/python
    exec runuser -u lightning -- /usr/bin/python3 -m lnmeshctl.leaf_rpc
    ;;
  *)
    echo "leaf-control-shell: command not permitted" >&2
    exit 126
    ;;
esac
