set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
date --iso-8601=ns --utc
install -d -m 0700 /var/backups/lnmesh/initial
if ! test -f /var/backups/lnmesh/initial/chrony.conf; then
  test ! -f /etc/chrony/chrony.conf || cp -a /etc/chrony/chrony.conf /var/backups/lnmesh/initial/chrony.conf
fi
printf 'iperf3 iperf3/start_daemon boolean false\n' | debconf-set-selections
apt-get update -qq
apt-get install -y --no-install-recommends batctl chrony jq iperf3 libsctp1 tcpdump python3 curl ca-certificates gnupg
install -d -m 0750 /etc/lnmesh
echo '--- package versions ---'
dpkg-query -W batctl chrony jq iperf3 libsctp1 tcpdump python3 curl ca-certificates gnupg
date --iso-8601=ns --utc
