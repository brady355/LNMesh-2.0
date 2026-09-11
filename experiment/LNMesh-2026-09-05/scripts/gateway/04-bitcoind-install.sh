#!/bin/bash
# Phase 4.1-4.2 on A: install Bitcoin Core, create user, generate rpcauth.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BTC_VER="${BTC_VER:-29.1}"
cd /tmp
if ! command -v bitcoind >/dev/null || ! bitcoind --version | grep -q "v${BTC_VER}"; then
  curl -fsSLO "https://bitcoincore.org/bin/bitcoin-core-${BTC_VER}/bitcoin-${BTC_VER}-aarch64-linux-gnu.tar.gz"
  curl -fsSLO "https://bitcoincore.org/bin/bitcoin-core-${BTC_VER}/SHA256SUMS"
  grep "bitcoin-${BTC_VER}-aarch64-linux-gnu.tar.gz" SHA256SUMS | sha256sum -c -
  tar xzf "bitcoin-${BTC_VER}-aarch64-linux-gnu.tar.gz"
  install -m 755 "bitcoin-${BTC_VER}/bin/bitcoind" "bitcoin-${BTC_VER}/bin/bitcoin-cli" /usr/local/bin/
  rm -rf "bitcoin-${BTC_VER}" "bitcoin-${BTC_VER}-aarch64-linux-gnu.tar.gz" SHA256SUMS
fi
bitcoind --version | head -1
id bitcoin >/dev/null 2>&1 || useradd -r -m -d /var/lib/bitcoind -s /usr/sbin/nologin bitcoin
mkdir -p /etc/lnmesh
if [ ! -f /etc/lnmesh/rpcauth.txt ]; then
  curl -fsSL "https://raw.githubusercontent.com/bitcoin/bitcoin/v${BTC_VER}/share/rpcauth/rpcauth.py" | python3 - lnmesh > /etc/lnmesh/rpcauth.txt
  chmod 600 /etc/lnmesh/rpcauth.txt
fi
echo "rpcauth generated: $(grep -c '^rpcauth=' /etc/lnmesh/rpcauth.txt) line(s)"
