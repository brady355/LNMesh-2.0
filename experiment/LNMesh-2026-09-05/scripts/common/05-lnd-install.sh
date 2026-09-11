#!/bin/bash
# Phase 5.1 on all: install LND, create user.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LND_VER="${LND_VER:-v0.19.2-beta}"
cd /tmp
if ! command -v lnd >/dev/null || ! lnd --version | grep -q "${LND_VER#v}"; then
  curl -fsSLO "https://github.com/lightningnetwork/lnd/releases/download/${LND_VER}/lnd-linux-arm64-${LND_VER}.tar.gz"
  curl -fsSLO "https://github.com/lightningnetwork/lnd/releases/download/${LND_VER}/manifest-${LND_VER}.txt"
  grep "lnd-linux-arm64-${LND_VER}.tar.gz" "manifest-${LND_VER}.txt" | sha256sum -c -
  tar xzf "lnd-linux-arm64-${LND_VER}.tar.gz"
  install -m 755 "lnd-linux-arm64-${LND_VER}/lnd" "lnd-linux-arm64-${LND_VER}/lncli" /usr/local/bin/
  rm -rf "lnd-linux-arm64-${LND_VER}" "lnd-linux-arm64-${LND_VER}.tar.gz" "manifest-${LND_VER}.txt"
fi
lnd --version
id lnd >/dev/null 2>&1 || useradd -r -m -d /var/lib/lnd -s /usr/sbin/nologin lnd
mkdir -p /etc/lnd
