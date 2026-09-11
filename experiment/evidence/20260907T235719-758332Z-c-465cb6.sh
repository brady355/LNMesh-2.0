export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
journalctl -u lnd-breach --no-pager -n 12 -o short-iso-precise; grep -E "^(listen|externalip)=" /etc/lnd/breach.conf