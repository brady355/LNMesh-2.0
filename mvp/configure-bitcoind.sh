#!/bin/bash
# Write bitcoin.conf for the a-b-c Bitcoin bus, install the unit, start.
# Usage: sudo bash -s <a|b|c> < configure-bitcoind.sh
# Bus: a listens for b. b listens for c and connects to a. c connects to b only.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
L="$1"
case "$L" in
  a) IP=10.10.0.1; PEER=''; ;;
  b) IP=10.10.0.2; PEER='addnode=10.10.0.1:18444'; ;;
  c) IP=10.10.0.3; PEER='connect=10.10.0.2:18444'; ;;
  *) echo "usage: a|b|c"; exit 1;;
esac
source /etc/lnmesh/rpcauth.env
cat > /var/lib/bitcoind/bitcoin.conf <<CONF
regtest=1
server=1
txindex=1
blockfilterindex=1
peerblockfilters=1
fallbackfee=0.0001
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333

[regtest]
listen=1
bind=127.0.0.1
bind=$IP
whitelist=10.10.0.0/24
$PEER
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
$RPC_AUTH
CONF
chown bitcoin:bitcoin /var/lib/bitcoind/bitcoin.conf; chmod 600 /var/lib/bitcoind/bitcoin.conf
cat > /etc/systemd/system/bitcoind.service <<'UNIT'
[Unit]
Description=Bitcoin Core (regtest) for LNMesh
Requires=lnmesh-mesh.service
After=lnmesh-mesh.service

[Service]
User=bitcoin
Group=bitcoin
ExecStart=/usr/local/bin/bitcoind -datadir=/var/lib/bitcoind
Restart=on-failure
RestartSec=5
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
UNIT
cat > /usr/local/bin/bcli <<'B'
#!/bin/bash
exec sudo -u bitcoin /usr/local/bin/bitcoin-cli -datadir=/var/lib/bitcoind "$@"
B
cat > /usr/local/bin/mine <<'M'
#!/bin/bash
# mine N blocks (default 1) to the address in /etc/lnmesh/mine.addr
/usr/local/bin/bcli generatetoaddress "${1:-1}" "$(cat /etc/lnmesh/mine.addr)" >/dev/null && echo "mined ${1:-1}, height $(/usr/local/bin/bcli getblockcount)"
M
chmod 755 /usr/local/bin/bcli /usr/local/bin/mine
systemctl daemon-reload; systemctl enable bitcoind >/dev/null 2>&1; systemctl restart bitcoind
for i in $(seq 1 30); do bcli getblockchaininfo >/dev/null 2>&1 && break; sleep 1; done
echo "$L bitcoind=$(systemctl is-active bitcoind) height=$(bcli getblockcount) peers=$(bcli getpeerinfo | jq -c '[.[].addr]')"
