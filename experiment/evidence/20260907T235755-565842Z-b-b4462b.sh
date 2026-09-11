export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
journalctl -u lnd --since '15 minutes ago' --no-pager -o short-iso-precise | grep -iE 'breach|justice|revoked' | tail -60