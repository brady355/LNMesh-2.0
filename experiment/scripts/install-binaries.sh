set -euo pipefail
date --iso-8601=ns --utc
install -d -m 0755 /var/cache/lnmesh
cd /var/cache/lnmesh
lndver=v0.19.2-beta
lndfile=lnd-linux-arm64-$lndver.tar.gz
curl -fLsS --retry 3 --connect-timeout 10 --max-time 180 -o "$lndfile" "https://github.com/lightningnetwork/lnd/releases/download/$lndver/$lndfile"
curl -fLsS --retry 3 -o "manifest-$lndver.txt" "https://github.com/lightningnetwork/lnd/releases/download/$lndver/manifest-$lndver.txt"
awk -v f="$lndfile" '$2==f {print; found=1} END {if(!found) exit 1}' "manifest-$lndver.txt" | sha256sum -c -
tar -xzf "$lndfile"
install -m 0755 "lnd-linux-arm64-$lndver/lnd" "lnd-linux-arm64-$lndver/lncli" /usr/local/bin/
lnd --version
sha256sum /usr/local/bin/lnd /usr/local/bin/lncli "$lndfile"
if test "$(hostname)" = pi1gateway; then
  btcver=29.1
  btcfile=bitcoin-$btcver-aarch64-linux-gnu.tar.gz
  curl -fLsS --retry 3 --connect-timeout 10 --max-time 180 -o "$btcfile" "https://bitcoincore.org/bin/bitcoin-core-$btcver/$btcfile"
  curl -fLsS --retry 3 -o bitcoin-SHA256SUMS "https://bitcoincore.org/bin/bitcoin-core-$btcver/SHA256SUMS"
  awk -v f="$btcfile" '$2==f {print; found=1} END {if(!found) exit 1}' bitcoin-SHA256SUMS | sha256sum -c -
  tar -xzf "$btcfile"
  install -m 0755 bitcoin-$btcver/bin/bitcoind bitcoin-$btcver/bin/bitcoin-cli /usr/local/bin/
  bitcoind --version | head -2
  sha256sum /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli "$btcfile"
fi
date --iso-8601=ns --utc
