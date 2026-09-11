export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
systemctl start lnd; timeout 90 bash -c "until lncli-mesh getinfo >/dev/null 2>&1; do sleep 1; done"; date --iso-8601=ns --utc