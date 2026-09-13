#!/bin/bash
# Install Bitcoin Core from a tarball already copied to /tmp (any host).
# Usage: sudo bash -s 29.1 < install-bitcoind.sh
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
V="${1:-29.1}"; T="/tmp/bitcoin-$V-aarch64-linux-gnu.tar.gz"
if ! command -v bitcoind >/dev/null || ! bitcoind --version | grep -q "v$V"; then
  [ -f "$T" ] || { echo "missing $T"; exit 1; }
  cd /tmp && tar xzf "$T"
  install -m 755 "bitcoin-$V/bin/bitcoind" "bitcoin-$V/bin/bitcoin-cli" /usr/local/bin/
  rm -rf "bitcoin-$V"
fi
id bitcoin >/dev/null 2>&1 || useradd -r -m -d /var/lib/bitcoind -s /usr/sbin/nologin bitcoin
mkdir -p /etc/lnmesh
if [ ! -f /etc/lnmesh/rpcauth.env ]; then
  python3 - > /etc/lnmesh/rpcauth.env <<'PY'
import hmac, hashlib, secrets, base64
user = "lnmesh"; salt = secrets.token_hex(16)
pw = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")
h = hmac.new(salt.encode(), pw.encode(), hashlib.sha256).hexdigest()
print(f"RPC_USER='{user}'\nRPC_PASS='{pw}'\nRPC_AUTH='rpcauth={user}:{salt}${h}'")
PY
  chmod 600 /etc/lnmesh/rpcauth.env
fi
bitcoind --version | head -1
