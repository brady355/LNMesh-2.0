set -euo pipefail
case "$(hostname)" in pi1gateway) letter=a;; pi2) letter=b;; pi3) letter=c;; *) exit 2;; esac
source /etc/lnmesh/mesh.env
id lnd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/lnd --create-home --shell /usr/sbin/nologin lnd
install -d -m 0750 -o lnd -g lnd /var/lib/lnd
install -d -m 0750 -o root -g lnd /etc/lnd
python3 - "$letter" "$MESH_IP" <<'PY'
import pathlib,sys,json
letter,addr=sys.argv[1:]
conf=f'''[Application Options]
alias=lnmesh-{letter}
listen={addr}:9735
externalip={addr}
rpclisten=127.0.0.1:10009
restlisten=127.0.0.1:8080
noseedbackup=true
debuglevel=info

[Bitcoin]
bitcoin.regtest=true
bitcoin.node={'bitcoind' if letter=='a' else 'neutrino'}
bitcoin.defaultremotedelay=1008
'''
if letter=='a':
    c=json.loads(pathlib.Path('/etc/lnmesh/bitcoin-rpc.json').read_text())
    conf+=f'''
[Bitcoind]
bitcoind.rpchost=127.0.0.1:18443
bitcoind.rpcuser={c['user']}
bitcoind.rpcpass={c['password']}
bitcoind.zmqpubrawblock=tcp://127.0.0.1:28332
bitcoind.zmqpubrawtx=tcp://127.0.0.1:28333
'''
else:
    conf+='\n[neutrino]\nneutrino.connect=10.10.0.1:18444\n'
pathlib.Path('/etc/lnd/lnd.conf').write_text(conf)
PY
chown root:lnd /etc/lnd/lnd.conf
chmod 0640 /etc/lnd/lnd.conf
cat > /etc/systemd/system/lnd.service <<'EOF'
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
  sed -i '/^After=/a After=bitcoind.service\nWants=bitcoind.service' /etc/systemd/system/lnd.service
fi
cat > /usr/local/bin/lncli-mesh <<'EOF'
#!/bin/bash
exec runuser -u lnd -- /usr/local/bin/lncli --lnddir=/var/lib/lnd --network=regtest "$@"
EOF
chmod 0755 /usr/local/bin/lncli-mesh
systemctl daemon-reload
systemctl enable --now lnd
timeout 120 bash -c 'until lncli-mesh getinfo >/dev/null 2>&1; do sleep 1; done'
lncli-mesh getinfo
systemctl show lnd -p ActiveState -p MainPID -p MemoryCurrent
ss -lntp | grep -E '9735|10009|8080'
