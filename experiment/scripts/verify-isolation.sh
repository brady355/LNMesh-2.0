set -euo pipefail
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
  if curl --noproxy '*' -IsS --connect-timeout 3 --max-time 5 "$target"; then echo "FAIL unexpected HTTPS access $target"; exit 1; else echo "PASS HTTPS unavailable $target"; fi
done
ping -I bat0 -c 3 -W 2 10.10.0.1
chronyc -n sources
lncli-mesh getinfo | jq '{alias,identity_pubkey,chains,block_height,num_active_channels,num_pending_channels}'
lncli-mesh walletbalance
lncli-mesh listchannels
ss -tnp | grep -E '18444|9735' || true
systemctl stop lnmesh-rollback.timer
echo 'PASS isolation and mesh access verified; automatic LAN recovery cancelled'
date --iso-8601=ns --utc
