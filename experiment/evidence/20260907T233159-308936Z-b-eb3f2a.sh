export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
date --iso-8601=ns --utc
for peer in 10.10.0.1 10.10.0.2 10.10.0.3; do
  timeout 45 bash -c 'until ping -I bat0 -c 1 -W 1 "$1" >/dev/null; do sleep 1; done' -- "$peer"
  ping -I bat0 -c 3 -W 2 "$peer"
done
batctl n
batctl o
iw dev wlan0 link
ip -br addr
echo "SSH_CONNECTION=$SSH_CONNECTION"
date --iso-8601=ns --utc
