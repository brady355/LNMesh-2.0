set -euo pipefail
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
  bcli getpeerinfo | jq '[.[] | {addr,inbound,subver,startingheight,connection_type,bytesrecv,bytessent}]'
else
  test -z "$(ip -4 route show default)"
  test -z "$(ip -6 route show default)"
  test -z "$(ip -o addr show dev eth0)"
  uuid=$(cat /etc/lnmesh/ethernet-profile.uuid)
  nmcli -f connection.id,connection.uuid,connection.autoconnect connection show uuid "$uuid"
fi
lncli-mesh getinfo | jq '{version,commit_hash,identity_pubkey,alias,chains,synced_to_chain,block_height,block_hash,num_active_channels,num_inactive_channels,num_pending_channels,num_peers}'
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
ss -tnp | grep -E '9735|9736|18444' || true
ps -C lnd,bitcoind -o pid,comm,etimes,rss,vsz,pcpu,pmem
free -b
df -B1 /
du -sb /var/lib/lnd
test ! -d /var/lib/bitcoind || du -sb /var/lib/bitcoind
vcgencmd measure_temp
vcgencmd get_throttled
echo '--- sanitized configuration ---'
grep -Ev 'rpcpass|rpcuser|rpcauth' /etc/lnd/lnd.conf
test ! -f /etc/bitcoin/bitcoin.conf || grep -Ev 'rpcpass|rpcuser|rpcauth' /etc/bitcoin/bitcoin.conf
cat /etc/chrony/chrony.conf
for file in /usr/local/bin/lnd /usr/local/bin/lncli /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli /usr/local/sbin/lnmesh-mesh /usr/local/bin/lnmesh-measure; do
  test ! -f "$file" || sha256sum "$file"
done
echo '--- package change history ---'
tail -65 /var/log/apt/history.log
date --iso-8601=ns --utc
