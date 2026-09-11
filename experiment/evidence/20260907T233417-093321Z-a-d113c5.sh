export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
test "$(hostname)" = pi1gateway
id bitcoin >/dev/null 2>&1 || useradd --system --home-dir /var/lib/bitcoind --create-home --shell /usr/sbin/nologin bitcoin
install -d -m 0750 -o bitcoin -g bitcoin /var/lib/bitcoind /etc/bitcoin
python3 - <<'PY'
import json,secrets,hmac,os,pathlib
p=pathlib.Path('/etc/lnmesh/bitcoin-rpc.json')
if not p.exists():
    p.write_text(json.dumps({'user':'lnmesh','password':secrets.token_hex(32),'salt':secrets.token_hex(16)}))
    p.chmod(0o600)
c=json.loads(p.read_text())
auth=c['user']+':'+c['salt']+'$'+hmac.new(c['salt'].encode(),c['password'].encode(),'sha256').hexdigest()
conf='''regtest=1
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
'''
pathlib.Path('/etc/bitcoin/bitcoin.conf').write_text(conf)
PY
chown root:bitcoin /etc/bitcoin/bitcoin.conf
chmod 0640 /etc/bitcoin/bitcoin.conf
cat > /etc/systemd/system/bitcoind.service <<'EOF'
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
cat > /usr/local/bin/bcli <<'EOF'
#!/bin/bash
exec runuser -u bitcoin -- /usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoind -regtest "$@"
EOF
chmod 0755 /usr/local/bin/bcli
systemctl daemon-reload
systemctl enable --now bitcoind
timeout 60 bash -c 'until bcli getblockchaininfo >/dev/null 2>&1; do sleep 1; done'
bcli getblockchaininfo
bcli getindexinfo
ss -lntp | grep -E '1844[34]|2833[23]'
