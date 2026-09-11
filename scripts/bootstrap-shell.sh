#!/usr/bin/env bash
# Restricted command used only by the deployment bootstrap public key.
set -euo pipefail
case "${SSH_ORIGINAL_COMMAND:-}" in
  describe)
    serial="$(awk -F ': ' '/^Serial/ {print $2; exit}' /proc/cpuinfo)"
    if [[ -z "$serial" && -r /sys/firmware/devicetree/base/serial-number ]]; then
      serial="$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number)"
    fi
    mac="$(cat /sys/class/net/wlan0/address)"
    fingerprint="$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
    /usr/bin/python3 -c 'import json,sys; print(json.dumps(dict(zip(("serial","mac","ssh_fingerprint"),sys.argv[1:]))))' "$serial" "$mac" "$fingerprint"
    ;;
  enroll)
    export PYTHONPATH=/usr/local/lib/lnmesh/python
    exec /usr/bin/python3 -m lnmeshctl.enrollment
    ;;
  *)
    echo "bootstrap-shell: command not permitted" >&2
    exit 126
    ;;
esac
