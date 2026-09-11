set -euo pipefail
date --iso-8601=ns --utc
id
echo '--- root file and service access ---'
python3 - <<'PY'
import tempfile,os
with tempfile.NamedTemporaryFile(prefix='lnmesh-preflight-',dir='/root') as f:
    f.write(b'lnmesh-test'); f.flush(); os.fsync(f.fileno())
    assert open(f.name,'rb').read()==b'lnmesh-test'
print('root write read fsync cleanup passed')
PY
systemctl show ssh -p ActiveState -p SubState
systemctl is-active ssh
echo '--- module and network administration ---'
modprobe batman-adv
ip link add lnmesh-pft type dummy
ip link set lnmesh-pft up
ip -br link show lnmesh-pft
ip link delete lnmesh-pft
modinfo batman-adv | head -15
echo '--- hardware and time ---'
tr -d '\0' < /proc/device-tree/model; echo
uname -a
cat /etc/os-release
free -b
df -B1 /
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS
vcgencmd measure_temp
vcgencmd get_throttled
timedatectl show -p NTPSynchronized -p Timezone
ip -j addr
ip -j route
iw dev
rfkill list
echo '--- package installation simulation ---'
apt-get -s install batctl chrony jq iperf3 libsctp1 tcpdump python3 curl ca-certificates gnupg
echo '--- installed application state ---'
for d in /var/lib/lnd /var/lib/bitcoind /var/lib/lnmesh; do
  if test -e "$d"; then ls -ld "$d"; else echo "$d absent"; fi
done
date --iso-8601=ns --utc
