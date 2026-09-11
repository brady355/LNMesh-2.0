export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
test "$(hostname)" != pi1gateway
ping -I bat0 -c 2 -W 2 10.10.0.1
uuid=$(nmcli -g GENERAL.CON-UUID device show eth0)
test -n "$uuid" && test "$uuid" != --
printf '%s\n' "$uuid" > /etc/lnmesh/ethernet-profile.uuid
cat > /usr/local/sbin/lnmesh-restore-lan <<'EOF'
#!/bin/bash
set -euo pipefail
uuid=$(cat /etc/lnmesh/ethernet-profile.uuid)
nmcli connection modify uuid "$uuid" connection.autoconnect yes
nmcli connection up uuid "$uuid"
EOF
chmod 0755 /usr/local/sbin/lnmesh-restore-lan
# A five minute automatic recovery is cancelled only after a fresh mesh SSH check.
systemd-run --unit=lnmesh-rollback --on-active=5min /usr/local/sbin/lnmesh-restore-lan
nmcli connection modify uuid "$uuid" connection.autoconnect no
nmcli device disconnect eth0
rfkill block bluetooth
ip -br addr
ip -j route
ip -6 -j route
date --iso-8601=ns --utc
