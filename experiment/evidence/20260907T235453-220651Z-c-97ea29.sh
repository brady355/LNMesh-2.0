export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
test "$(hostname)" = pi3
test ! -e /var/lib/lnd-breach
test "$(lncli-mesh getinfo | jq -r '.chains[0].network')" = regtest
install -d -m 0750 -o lnd -g lnd /var/lib/lnd-breach
sed -e 's/^alias=.*/alias=lnmesh-c-breach/' \
  -e 's/:9735$/:9736/' -e 's/:10009$/:10010/' -e 's/:8080$/:8081/' \
  /etc/lnd/lnd.conf > /etc/lnd/breach.conf
chown root:lnd /etc/lnd/breach.conf
chmod 0640 /etc/lnd/breach.conf
cat > /etc/systemd/system/lnd-breach.service <<'EOF'
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
cat > /usr/local/bin/lncli-breach <<'EOF'
#!/bin/bash
exec runuser -u lnd -- /usr/local/bin/lncli --lnddir=/var/lib/lnd-breach --rpcserver=localhost:10010 --network=regtest "$@"
EOF
chmod 0755 /usr/local/bin/lncli-breach
systemctl daemon-reload
systemctl start lnd-breach
timeout 120 bash -c 'until lncli-breach getinfo | jq -e .synced_to_chain >/dev/null 2>&1; do sleep 2; done'
lncli-breach getinfo
lncli-breach walletbalance
