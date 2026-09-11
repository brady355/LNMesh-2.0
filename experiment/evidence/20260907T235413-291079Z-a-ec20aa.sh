export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
test "$(systemctl is-active bitcoind || true)" = inactive; date --iso-8601=ns --utc