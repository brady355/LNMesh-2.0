export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -e
test "$(systemctl is-active lnd-breach || true)" = inactive
test "$(systemctl is-enabled lnd-breach || true)" != enabled
systemctl is-active lnd