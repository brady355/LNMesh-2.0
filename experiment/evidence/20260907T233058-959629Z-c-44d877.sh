export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
case "$(hostname)" in pi1gateway) address=10.10.0.1;; pi2) address=10.10.0.2;; pi3) address=10.10.0.3;; *) exit 2;; esac
cat > /etc/NetworkManager/conf.d/99-lnmesh-unmanaged.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
nmcli general reload
nmcli device set wlan0 managed no
cat > /usr/local/sbin/lnmesh-mesh <<'EOF'
#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
source /etc/lnmesh/mesh.env
modprobe batman-adv
rfkill unblock wlan
iw reg set US
ip link set wlan0 down
iw dev wlan0 set type ibss
ip link set wlan0 up
iw dev wlan0 set power_save off || true
iw dev wlan0 ibss leave 2>/dev/null || true
iw dev wlan0 ibss join lnmesh-20260907 2412 fixed-freq 02:CA:FE:00:00:01
batctl if add wlan0
ip link set bat0 up
ip addr replace "$MESH_IP/24" dev bat0
EOF
printf 'MESH_IP=%s\n' "$address" > /etc/lnmesh/mesh.env
chmod 0755 /usr/local/sbin/lnmesh-mesh
cat > /etc/systemd/system/lnmesh-mesh.service <<'EOF'
[Unit]
Description=LNMesh batman adv over onboard ad hoc WiFi
After=NetworkManager.service
Wants=NetworkManager.service
Before=chrony.service bitcoind.service lnd.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lnmesh-mesh
RemainAfterExit=yes
TimeoutStartSec=60
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lnmesh-mesh.service
systemctl is-active lnmesh-mesh.service
ip -br addr
iw dev wlan0 info
batctl -v
batctl if
