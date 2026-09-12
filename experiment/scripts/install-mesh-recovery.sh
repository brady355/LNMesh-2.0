#!/bin/bash
# Install boot retries and conservative reconnection for the deployed IBSS mesh.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
test -x /usr/local/sbin/lnmesh-mesh
test -f /etc/lnmesh/mesh.env
case "$(hostname)" in pi1gateway|pi2|pi3) ;; *) exit 2 ;; esac

cat > /usr/local/sbin/lnmesh-mesh-health <<'EOF'
#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
source /etc/lnmesh/mesh.env

radio_ready() {
  iw dev wlan0 link 2>/dev/null | grep -q '^Joined IBSS ' &&
    ip -o -4 addr show dev bat0 2>/dev/null | grep -Fq " ${MESH_IP}/24 "
}

if [[ ${1:-} == --ready ]]; then
  for attempt in {1..20}; do
    if radio_ready; then exit 0; fi
    sleep 1
  done
  echo 'Mesh radio or bat0 address did not become ready within 20 seconds.' >&2
  exit 1
fi

# Only one health check runs at a time. The counter resets at every boot.
exec 9>/run/lnmesh-mesh-health.lock
flock -n 9 || exit 0
counter=/run/lnmesh-mesh-health.failures
failures=0
if [[ -r $counter ]]; then read -r failures < "$counter" || true; fi
[[ $failures =~ ^[0-9]+$ ]] || failures=0

# A stopped/failed service can leave its interfaces behind. Restore service
# supervision even when those leftover interfaces still pass traffic.
if ! systemctl is-active --quiet lnmesh-mesh.service; then
  echo 'Mesh service is not active; requesting startup.'
  systemctl --no-block start lnmesh-mesh.service
  printf '0\n' > "$counter"
  exit 0
fi

# One responsive peer establishes that this node has a usable mesh path.
# An absent second peer must not interrupt an otherwise working link.
if radio_ready; then
  for peer in 10.10.0.1 10.10.0.2 10.10.0.3; do
    [[ $peer == "$MESH_IP" ]] && continue
    if ping -n -I bat0 -c 1 -W 2 "$peer" >/dev/null 2>&1; then
      printf '0\n' > "$counter"
      echo "Mesh reachable via bat0: $peer"
      exit 0
    fi
  done
fi

failures=$((failures + 1))
printf '%s\n' "$failures" > "$counter"
if (( failures < 3 )); then
  echo "No reachable mesh peer: check $failures of 3."
  exit 0
fi

echo 'No reachable mesh peer for three checks; restarting the mesh service.'
systemctl --no-block restart lnmesh-mesh.service
printf '0\n' > "$counter"
EOF
chmod 0755 /usr/local/sbin/lnmesh-mesh-health

mkdir -p /etc/systemd/system/lnmesh-mesh.service.d
cat > /etc/systemd/system/lnmesh-mesh.service.d/recovery.conf <<'EOF'
[Unit]
Wants=sys-subsystem-net-devices-wlan0.device
After=sys-subsystem-net-devices-wlan0.device
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=10s
ExecStartPost=/usr/local/sbin/lnmesh-mesh-health --ready
EOF

cat > /etc/systemd/system/lnmesh-mesh-health.service <<'EOF'
[Unit]
Description=Check LNMesh connectivity and recover an isolated radio
After=lnmesh-mesh.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lnmesh-mesh-health
TimeoutStartSec=15s
EOF

cat > /etc/systemd/system/lnmesh-mesh-health.timer <<'EOF'
[Unit]
Description=Check LNMesh connectivity after boot and every minute

[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
RandomizedDelaySec=15s
AccuracySec=1s
Unit=lnmesh-mesh-health.service

[Install]
WantedBy=timers.target
EOF

bash -n /usr/local/sbin/lnmesh-mesh-health
systemd-analyze verify /etc/systemd/system/lnmesh-mesh.service \
  /etc/systemd/system/lnmesh-mesh-health.service \
  /etc/systemd/system/lnmesh-mesh-health.timer
systemctl daemon-reload
systemctl enable lnmesh-mesh.service
systemctl enable --now lnmesh-mesh-health.timer
systemctl is-enabled lnmesh-mesh.service lnmesh-mesh-health.timer
systemctl list-timers --all --no-pager lnmesh-mesh-health.timer
