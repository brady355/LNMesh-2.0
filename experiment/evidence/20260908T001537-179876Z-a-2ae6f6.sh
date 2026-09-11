export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -e
bash -n -c 'set -euo pipefail
test "$(hostname)" = pi1gateway
id bitcoin >/dev/null 2>&1 || useradd --system --home-dir /var/lib/bitcoind --create-home --shell /usr/sbin/nologin bitcoin
install -d -m 0750 -o bitcoin -g bitcoin /var/lib/bitcoind /etc/bitcoin
python3 - <<'"'"'PY'"'"'
import json,secrets,hmac,os,pathlib
p=pathlib.Path('"'"'/etc/lnmesh/bitcoin-rpc.json'"'"')
if not p.exists():
    p.write_text(json.dumps({'"'"'user'"'"':'"'"'lnmesh'"'"','"'"'password'"'"':secrets.token_hex(32),'"'"'salt'"'"':secrets.token_hex(16)}))
    p.chmod(0o600)
c=json.loads(p.read_text())
auth=c['"'"'user'"'"']+'"'"':'"'"'+c['"'"'salt'"'"']+'"'"'$'"'"'+hmac.new(c['"'"'salt'"'"'].encode(),c['"'"'password'"'"'].encode(),'"'"'sha256'"'"').hexdigest()
conf='"'"''"'"''"'"'regtest=1
server=1
txindex=1
blockfilterindex=1
peerblockfilters=1
dbcache=256
listenonion=0
discover=0
dnsseed=0
fixedseeds=0
rpcauth=[REDACTED]
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
[regtest]
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcport=18443
bind=10.10.0.1:18444
'"'"''"'"''"'"'
pathlib.Path('"'"'/etc/bitcoin/bitcoin.conf'"'"').write_text(conf)
PY
chown root:bitcoin /etc/bitcoin/bitcoin.conf
chmod 0640 /etc/bitcoin/bitcoin.conf
cat > /etc/systemd/system/bitcoind.service <<'"'"'EOF'"'"'
[Unit]
Description=LNMesh Bitcoin Core regtest chain and compact filters
After=lnmesh-mesh.service
Requires=lnmesh-mesh.service
[Service]
User=bitcoin
Group=bitcoin
ExecStart=/usr/local/bin/bitcoind -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoind
Restart=on-failure
RestartSec=3
TimeoutStopSec=120
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
[Install]
WantedBy=multi-user.target
EOF
cat > /usr/local/bin/bcli <<'"'"'EOF'"'"'
#!/bin/bash
exec runuser -u bitcoin -- /usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoind -regtest "$@"
EOF
chmod 0755 /usr/local/bin/bcli
systemctl daemon-reload
systemctl enable --now bitcoind
timeout 60 bash -c '"'"'until bcli getblockchaininfo >/dev/null 2>&1; do sleep 1; done'"'"'
bcli getblockchaininfo
bcli getindexinfo
ss -lntp | grep -E '"'"'1844[34]|2833[23]'"'"'
'
bash -n -c 'set -euo pipefail
case "$(hostname)" in pi1gateway) letter=a;; pi2) letter=b;; pi3) letter=c;; *) exit 2;; esac
source /etc/lnmesh/mesh.env
id lnd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/lnd --create-home --shell /usr/sbin/nologin lnd
install -d -m 0750 -o lnd -g lnd /var/lib/lnd
install -d -m 0750 -o root -g lnd /etc/lnd
python3 - "$letter" "$MESH_IP" <<'"'"'PY'"'"'
import pathlib,sys,json
letter,addr=sys.argv[1:]
conf=f'"'"''"'"''"'"'[Application Options]
alias=lnmesh-{letter}
listen={addr}:9735
externalip={addr}
rpclisten=127.0.0.1:10009
restlisten=127.0.0.1:8080
noseedbackup=true
debuglevel=info

[Bitcoin]
bitcoin.regtest=true
bitcoin.node={'"'"'bitcoind'"'"' if letter=='"'"'a'"'"' else '"'"'neutrino'"'"'}
bitcoin.defaultremotedelay=1008
'"'"''"'"''"'"'
if letter=='"'"'a'"'"':
    c=json.loads(pathlib.Path('"'"'/etc/lnmesh/bitcoin-rpc.json'"'"').read_text())
    conf+=f'"'"''"'"''"'"'
[Bitcoind]
bitcoind.rpchost=127.0.0.1:18443
bitcoind.rpcuser={c['"'"'user'"'"']}
bitcoind.rpcpass=[REDACTED]
bitcoind.zmqpubrawblock=tcp://127.0.0.1:28332
bitcoind.zmqpubrawtx=tcp://127.0.0.1:28333
'"'"''"'"''"'"'
else:
    conf+='"'"'\n[neutrino]\nneutrino.connect=10.10.0.1:18444\n'"'"'
pathlib.Path('"'"'/etc/lnd/lnd.conf'"'"').write_text(conf)
PY
chown root:lnd /etc/lnd/lnd.conf
chmod 0640 /etc/lnd/lnd.conf
cat > /etc/systemd/system/lnd.service <<'"'"'EOF'"'"'
[Unit]
Description=LNMesh Lightning node on regtest
After=lnmesh-mesh.service chrony.service
Requires=lnmesh-mesh.service
Wants=chrony.service
[Service]
User=lnd
Group=lnd
ExecStart=/usr/local/bin/lnd --lnddir=/var/lib/lnd --configfile=/etc/lnd/lnd.conf
Restart=always
RestartSec=3
TimeoutStopSec=120
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
[Install]
WantedBy=multi-user.target
EOF
if test "$letter" = a; then
  sed -i '"'"'/^After=/a After=bitcoind.service\nWants=bitcoind.service'"'"' /etc/systemd/system/lnd.service
fi
cat > /usr/local/bin/lncli-mesh <<'"'"'EOF'"'"'
#!/bin/bash
exec runuser -u lnd -- /usr/local/bin/lncli --lnddir=/var/lib/lnd --network=regtest "$@"
EOF
chmod 0755 /usr/local/bin/lncli-mesh
systemctl daemon-reload
systemctl enable --now lnd
timeout 120 bash -c '"'"'until lncli-mesh getinfo >/dev/null 2>&1; do sleep 1; done'"'"'
lncli-mesh getinfo
systemctl show lnd -p ActiveState -p MainPID -p MemoryCurrent
ss -lntp | grep -E '"'"'9735|10009|8080'"'"'
'
bash -n -c 'set -euo pipefail
case "$(hostname)" in pi1gateway) address=10.10.0.1;; pi2) address=10.10.0.2;; pi3) address=10.10.0.3;; *) exit 2;; esac
cat > /etc/NetworkManager/conf.d/99-lnmesh-unmanaged.conf <<'"'"'EOF'"'"'
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
nmcli general reload
nmcli device set wlan0 managed no
cat > /usr/local/sbin/lnmesh-mesh <<'"'"'EOF'"'"'
#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
source /etc/lnmesh/mesh.env
modprobe batman-adv
rfkill unblock wlan
iw reg set US
ip link set wlan0 down
iw dev wlan0 set type ibss
ip link set wlan0 up
iw dev wlan0 set power_save off || true
iw dev wlan0 ibss leave 2>/dev/null || true
iw dev wlan0 ibss join lnmesh-20260907 2412 fixed-freq 02:CA:FE:00:00:01
batctl if add wlan0
ip link set bat0 address "$MESH_MAC"
ip link set bat0 up
ip addr replace "$MESH_IP/24" dev bat0
EOF
# Preserve an existing mesh MAC, or derive a stable locally administered address.
if test -f /sys/class/net/bat0/address; then
  mesh_mac=$(cat /sys/class/net/bat0/address)
else
  wifi_mac=$(cat /sys/class/net/wlan0/address)
  mesh_mac="02:${wifi_mac#*:}"
fi
printf '"'"'MESH_IP=%s\nMESH_MAC=%s\n'"'"' "$address" "$mesh_mac" > /etc/lnmesh/mesh.env
chmod 0755 /usr/local/sbin/lnmesh-mesh
cat > /etc/systemd/system/lnmesh-mesh.service <<'"'"'EOF'"'"'
[Unit]
Description=LNMesh batman adv over onboard ad hoc WiFi
After=NetworkManager.service
Wants=NetworkManager.service
Before=chrony.service bitcoind.service lnd.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lnmesh-mesh
RemainAfterExit=yes
TimeoutStartSec=60
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lnmesh-mesh.service
systemctl is-active lnmesh-mesh.service
ip -br addr
iw dev wlan0 info
batctl -v
batctl if
'
bash -n -c 'set -euo pipefail
test -f /var/backups/lnmesh/initial/chrony.conf || cp -a /etc/chrony/chrony.conf /var/backups/lnmesh/initial/chrony.conf
if test "$(hostname)" = pi1gateway; then
  cp /var/backups/lnmesh/initial/chrony.conf /etc/chrony/chrony.conf
  printf '"'"'\nallow 10.10.0.0/24\n'"'"' >> /etc/chrony/chrony.conf
else
  cat > /etc/chrony/chrony.conf <<'"'"'EOF'"'"'
server 10.10.0.1 iburst minpoll 4 maxpoll 6
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
fi
install -d /etc/systemd/system/chrony.service.d
cat > /etc/systemd/system/chrony.service.d/lnmesh.conf <<'"'"'EOF'"'"'
[Unit]
After=lnmesh-mesh.service
Requires=lnmesh-mesh.service
EOF
systemctl daemon-reload
systemctl restart chrony
chronyc waitsync 30 0.1 0 2
chronyc -n tracking
chronyc -n sources -v
date --iso-8601=ns --utc
'
bash -n -c 'set -euo pipefail
test "$(hostname)" = pi3
test ! -e /var/lib/lnd-breach
test "$(lncli-mesh getinfo | jq -r '"'"'.chains[0].network'"'"')" = regtest
install -d -m 0750 -o lnd -g lnd /var/lib/lnd-breach
sed -e '"'"'s/^alias=.*/alias=lnmesh-c-breach/'"'"' -e '"'"'s/^externalip=.*/externalip=10.10.0.3:9736/'"'"' \
  -e '"'"'s/:9735$/:9736/'"'"' -e '"'"'s/:10009$/:10010/'"'"' -e '"'"'s/:8080$/:8081/'"'"' \
  /etc/lnd/lnd.conf > /etc/lnd/breach.conf
chown root:lnd /etc/lnd/breach.conf
chmod 0640 /etc/lnd/breach.conf
cat > /etc/systemd/system/lnd-breach.service <<'"'"'EOF'"'"'
[Unit]
Description=Disposable LNMesh regtest breach experiment node
After=lnmesh-mesh.service chrony.service
Requires=lnmesh-mesh.service
[Service]
User=lnd
Group=lnd
ExecStart=/usr/local/bin/lnd --lnddir=/var/lib/lnd-breach --configfile=/etc/lnd/breach.conf
Restart=on-failure
RestartSec=3
TimeoutStopSec=120
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
EOF
cat > /usr/local/bin/lncli-breach <<'"'"'EOF'"'"'
#!/bin/bash
exec runuser -u lnd -- /usr/local/bin/lncli --lnddir=/var/lib/lnd-breach --rpcserver=localhost:10010 --network=regtest "$@"
EOF
chmod 0755 /usr/local/bin/lncli-breach
systemctl daemon-reload
systemctl start lnd-breach
timeout 120 bash -c '"'"'until lncli-breach getinfo | jq -e .synced_to_chain >/dev/null 2>&1; do sleep 2; done'"'"'
lncli-breach getinfo
lncli-breach walletbalance
'
bash -n -c 'set -euo pipefail
date --iso-8601=ns --utc
hostnamectl
uname -a
dpkg-query -W batctl chrony jq iperf3 libsctp1 tcpdump python3 curl ca-certificates gnupg
systemctl is-active lnmesh-mesh chrony lnd
systemctl is-enabled lnmesh-mesh chrony lnd
if test "$(hostname)" = pi1gateway; then
  systemctl is-active bitcoind
  sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
  bcli getblockchaininfo
  bcli getindexinfo
  bcli getpeerinfo | jq '"'"'[.[] | {addr,inbound,subver,startingheight,connection_type,bytesrecv,bytessent}]'"'"'
else
  test -z "$(ip -4 route show default)"
  test -z "$(ip -6 route show default)"
  test -z "$(ip -o addr show dev eth0)"
  uuid=$(cat /etc/lnmesh/ethernet-profile.uuid)
  nmcli -f connection.id,connection.uuid,connection.autoconnect connection show uuid "$uuid"
fi
lncli-mesh getinfo | jq '"'"'{version,commit_hash,identity_pubkey,alias,chains,synced_to_chain,block_height,block_hash,num_active_channels,num_inactive_channels,num_pending_channels,num_peers}'"'"'
lncli-mesh listchannels
lncli-mesh walletbalance
lncli-mesh channelbalance
lncli-mesh pendingchannels
lncli-mesh closedchannels
lncli-mesh listpeers
ip -j addr
ip -j route
ip -6 -j route
ip -s -j link
batctl n
batctl o
iw dev wlan0 info
iw dev wlan0 link
iw dev wlan0 station dump
iw reg get
rfkill list
chronyc -n tracking
chronyc -n sources
ss -tnp | grep -E '"'"'9735|9736|18444'"'"' || true
ps -C lnd,bitcoind -o pid,comm,etimes,rss,vsz,pcpu,pmem
free -b
df -B1 /
du -sb /var/lib/lnd
test ! -d /var/lib/bitcoind || du -sb /var/lib/bitcoind
vcgencmd measure_temp
vcgencmd get_throttled
echo '"'"'--- sanitized configuration ---'"'"'
grep -Ev '"'"'rpcpass|rpcuser|rpcauth'"'"' /etc/lnd/lnd.conf
test ! -f /etc/bitcoin/bitcoin.conf || grep -Ev '"'"'rpcpass|rpcuser|rpcauth'"'"' /etc/bitcoin/bitcoin.conf
cat /etc/chrony/chrony.conf
for file in /usr/local/bin/lnd /usr/local/bin/lncli /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli /usr/local/sbin/lnmesh-mesh /usr/local/bin/lnmesh-measure; do
  test ! -f "$file" || sha256sum "$file"
done
echo '"'"'--- package change history ---'"'"'
tail -65 /var/log/apt/history.log
date --iso-8601=ns --utc
'
bash -n -c 'set -euo pipefail
test "$(hostname)" = pi1gateway
cat > /etc/sysctl.d/90-lnmesh-no-forward.conf <<'"'"'EOF'"'"'
net.ipv4.ip_forward=0
net.ipv6.conf.all.forwarding=0
EOF
sysctl -p /etc/sysctl.d/90-lnmesh-no-forward.conf
ip -j route
ip -6 -j route
ss -tnp | grep -E '"'"'18444|9735'"'"' || true
'
bash -n -c 'set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
date --iso-8601=ns --utc
install -d -m 0700 /var/backups/lnmesh/initial
if ! test -f /var/backups/lnmesh/initial/chrony.conf; then
  test ! -f /etc/chrony/chrony.conf || cp -a /etc/chrony/chrony.conf /var/backups/lnmesh/initial/chrony.conf
fi
printf '"'"'iperf3 iperf3/start_daemon boolean false\n'"'"' | debconf-set-selections
apt-get update -qq
apt-get install -y --no-install-recommends batctl chrony jq iperf3 libsctp1 tcpdump python3 curl ca-certificates gnupg
install -d -m 0750 /etc/lnmesh
echo '"'"'--- package versions ---'"'"'
dpkg-query -W batctl chrony jq iperf3 libsctp1 tcpdump python3 curl ca-certificates gnupg
date --iso-8601=ns --utc
'
bash -n -c 'set -euo pipefail
date --iso-8601=ns --utc
install -d -m 0755 /var/cache/lnmesh
cd /var/cache/lnmesh
lndver=v0.19.2-beta
lndfile=lnd-linux-arm64-$lndver.tar.gz
curl -fLsS --retry 3 --connect-timeout 10 --max-time 180 -o "$lndfile" "https://github.com/lightningnetwork/lnd/releases/download/$lndver/$lndfile"
curl -fLsS --retry 3 -o "manifest-$lndver.txt" "https://github.com/lightningnetwork/lnd/releases/download/$lndver/manifest-$lndver.txt"
awk -v f="$lndfile" '"'"'$2==f {print; found=1} END {if(!found) exit 1}'"'"' "manifest-$lndver.txt" | sha256sum -c -
tar -xzf "$lndfile"
install -m 0755 "lnd-linux-arm64-$lndver/lnd" "lnd-linux-arm64-$lndver/lncli" /usr/local/bin/
lnd --version
sha256sum /usr/local/bin/lnd /usr/local/bin/lncli "$lndfile"
if test "$(hostname)" = pi1gateway; then
  btcver=29.1
  btcfile=bitcoin-$btcver-aarch64-linux-gnu.tar.gz
  curl -fLsS --retry 3 --connect-timeout 10 --max-time 180 -o "$btcfile" "https://bitcoincore.org/bin/bitcoin-core-$btcver/$btcfile"
  curl -fLsS --retry 3 -o bitcoin-SHA256SUMS "https://bitcoincore.org/bin/bitcoin-core-$btcver/SHA256SUMS"
  awk -v f="$btcfile" '"'"'$2==f {print; found=1} END {if(!found) exit 1}'"'"' bitcoin-SHA256SUMS | sha256sum -c -
  tar -xzf "$btcfile"
  install -m 0755 bitcoin-$btcver/bin/bitcoind bitcoin-$btcver/bin/bitcoin-cli /usr/local/bin/
  bitcoind --version | head -2
  sha256sum /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli "$btcfile"
fi
date --iso-8601=ns --utc
'
bash -n -c 'set -euo pipefail
test "$(hostname)" != pi1gateway
ping -I bat0 -c 2 -W 2 10.10.0.1
uuid=$(nmcli -g GENERAL.CON-UUID device show eth0)
test -n "$uuid" && test "$uuid" != --
printf '"'"'%s\n'"'"' "$uuid" > /etc/lnmesh/ethernet-profile.uuid
cat > /usr/local/sbin/lnmesh-restore-lan <<'"'"'EOF'"'"'
#!/bin/bash
set -euo pipefail
uuid=$(cat /etc/lnmesh/ethernet-profile.uuid)
nmcli connection modify uuid "$uuid" connection.autoconnect yes
nmcli connection up uuid "$uuid"
EOF
chmod 0755 /usr/local/sbin/lnmesh-restore-lan
# A five minute automatic recovery is cancelled only after a fresh mesh SSH check.
systemd-run --unit=lnmesh-rollback --on-active=5min /usr/local/sbin/lnmesh-restore-lan
nmcli connection modify uuid "$uuid" connection.autoconnect no
nmcli device disconnect eth0
rfkill block bluetooth
ip -br addr
ip -j route
ip -6 -j route
date --iso-8601=ns --utc
'
bash -n -c 'set -euo pipefail
mesh_mac=$(cat /sys/class/net/bat0/address)
sed -i '"'"'/^MESH_MAC=/d'"'"' /etc/lnmesh/mesh.env
printf '"'"'MESH_MAC=%s\n'"'"' "$mesh_mac" >> /etc/lnmesh/mesh.env
python3 - <<'"'"'PY'"'"'
from pathlib import Path
p=Path('"'"'/usr/local/sbin/lnmesh-mesh'"'"')
s=p.read_text()
if '"'"'ip link set bat0 address'"'"' not in s:
    s=s.replace('"'"'ip link set bat0 up'"'"','"'"'ip link set bat0 address "$MESH_MAC"\nip link set bat0 up'"'"')
p.write_text(s)
PY
bash -n /usr/local/sbin/lnmesh-mesh
cat /etc/lnmesh/mesh.env
sha256sum /usr/local/sbin/lnmesh-mesh
'
bash -n -c 'set -euo pipefail
date --iso-8601=ns --utc
id
echo '"'"'--- root file and service access ---'"'"'
python3 - <<'"'"'PY'"'"'
import tempfile,os
with tempfile.NamedTemporaryFile(prefix='"'"'lnmesh-preflight-'"'"',dir='"'"'/root'"'"') as f:
    f.write(b'"'"'lnmesh-test'"'"'); f.flush(); os.fsync(f.fileno())
    assert open(f.name,'"'"'rb'"'"').read()==b'"'"'lnmesh-test'"'"'
print('"'"'root write read fsync cleanup passed'"'"')
PY
systemctl show ssh -p ActiveState -p SubState
systemctl is-active ssh
echo '"'"'--- module and network administration ---'"'"'
modprobe batman-adv
ip link add lnmesh-pft type dummy
ip link set lnmesh-pft up
ip -br link show lnmesh-pft
ip link delete lnmesh-pft
modinfo batman-adv | head -15
echo '"'"'--- hardware and time ---'"'"'
tr -d '"'"'\0'"'"' < /proc/device-tree/model; echo
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
echo '"'"'--- package installation simulation ---'"'"'
apt-get -s install batctl chrony jq iperf3 libsctp1 tcpdump python3 curl ca-certificates gnupg
echo '"'"'--- installed application state ---'"'"'
for d in /var/lib/lnd /var/lib/bitcoind /var/lib/lnmesh; do
  if test -e "$d"; then ls -ld "$d"; else echo "$d absent"; fi
done
date --iso-8601=ns --utc
'
bash -n -c 'set -euo pipefail
test "$(hostname)" != pi1gateway
date --iso-8601=ns --utc
test -z "$(ip -4 route show default)"
test -z "$(ip -6 route show default)"
test -z "$(ip -o addr show dev eth0)"
ip -j addr
ip -j route
ip -6 -j route
rfkill list
for target in 10.17.4.1 1.1.1.1 8.8.8.8; do
  if ping -c 1 -W 2 "$target"; then echo "FAIL unexpected access $target"; exit 1; else echo "PASS unreachable $target"; fi
done
for target in https://example.com https://1.1.1.1; do
  if curl --noproxy '"'"'*'"'"' -IsS --connect-timeout 3 --max-time 5 "$target"; then echo "FAIL unexpected HTTPS access $target"; exit 1; else echo "PASS HTTPS unavailable $target"; fi
done
ping -I bat0 -c 3 -W 2 10.10.0.1
chronyc -n sources
lncli-mesh getinfo | jq '"'"'{alias,identity_pubkey,chains,block_height,num_active_channels,num_pending_channels}'"'"'
lncli-mesh walletbalance
lncli-mesh listchannels
ss -tnp | grep -E '"'"'18444|9735'"'"' || true
systemctl stop lnmesh-rollback.timer
echo '"'"'PASS isolation and mesh access verified; automatic LAN recovery cancelled'"'"'
date --iso-8601=ns --utc
'
bash -n -c 'set -euo pipefail
date --iso-8601=ns --utc
for peer in 10.10.0.1 10.10.0.2 10.10.0.3; do
  timeout 45 bash -c '"'"'until ping -I bat0 -c 1 -W 1 "$1" >/dev/null; do sleep 1; done'"'"' -- "$peer"
  ping -I bat0 -c 3 -W 2 "$peer"
done
batctl n
batctl o
iw dev wlan0 link
ip -br addr
echo "SSH_CONNECTION=${SSH_CONNECTION:-not-preserved-by-sudo}"
date --iso-8601=ns --utc
'
printf "PASS Bash syntax for 14 scripts\n"