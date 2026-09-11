#!/bin/bash
# Phase 1: base OS configuration. Idempotent. Run as root on every Pi.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TZ_NAME="${TZ_NAME:-America/Chicago}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"

echo "== apt"
apt-get update -qq
apt-get full-upgrade -y -qq
apt-get install -y -qq batctl chrony iw rfkill curl jq

echo "== timezone/locale"
timedatectl set-timezone "$TZ_NAME"
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen >/dev/null
update-locale LANG=en_US.UTF-8

echo "== wifi country + rfkill"
raspi-config nonint do_wifi_country "$WIFI_COUNTRY" || true
rfkill unblock wlan

echo "== NetworkManager: leave wlan0 unmanaged"
cat > /etc/NetworkManager/conf.d/99-lnmesh-unmanaged.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
systemctl restart NetworkManager

echo "== versions"
echo "kernel=$(uname -r) batctl=$(batctl -v | head -1) chrony=$(chronyd --version 2>&1 | head -1) iw=$(iw --version)"
nmcli -t device status | grep wlan0 || true
echo "== phase 1 done on $(hostname); rebooting"
