export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -e
cat /proc/sys/kernel/random/boot_id
systemctl is-active lnmesh-mesh chrony lnd
lncli-mesh getinfo >/dev/null