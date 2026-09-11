#!/usr/bin/env bash
# LNMesh build driver. Runs one phase of DOCUMENTATION.md from the laptop
# over SSH. Requires hosts.env and ~/.ssh/config entries lnmesh-a/b/c
# (see ssh/config.example). Phase 0 (flashing, cabling, SSH keys) is manual.
#
#   ./scripts/build.sh check     Phase 0.6/0.7 hand-off checks on all three
#   ./scripts/build.sh 1         base OS, packages, wlan0 unmanaged, reboot
#   ./scripts/build.sh 2         batman-adv mesh, verify neighbours
#   ./scripts/build.sh 3         chrony: A serves, B and C follow A
#   ./scripts/build.sh 4         Bitcoin Core regtest on A with block filters
#   ./scripts/build.sh 5         LND on all three, mine 101, record pubkeys
#   ./scripts/build.sh 6.1       A: forwarding off
#   ./scripts/build.sh 6.2       print the ProxyJump SSH config, test it
#   ./scripts/build.sh 6.3       B, C: wired profile off, prove isolation (cables already out)
#   ./scripts/build.sh status    one line per Pi
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f hosts.env ] || { echo "hosts.env missing: cp hosts.env.example hosts.env and fill it in"; exit 1; }
source hosts.env
RP='export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin;'
mip() { case $1 in a) echo "$MESH_A";; b) echo "$MESH_B";; c) echo "$MESH_C";; esac; }
say() { printf '\n== %s\n' "$*"; }
rs() { local h=$1; shift; ssh -o BatchMode=yes "lnmesh-$h" "$RP $*"; }            # remote shell
sudo_script() { local h=$1 s=$2; shift 2; ssh -o BatchMode=yes "lnmesh-$h" "sudo bash -s $*" < "$s"; }
reboot_wait() { # reboot_wait a b c
  for h in "$@"; do ssh -o BatchMode=yes "lnmesh-$h" 'sudo reboot' >/dev/null 2>&1 || true; done
  echo "rebooting $*; waiting"; sleep 20
  for h in "$@"; do for i in $(seq 1 40); do ssh -o BatchMode=yes -o ConnectTimeout=3 "lnmesh-$h" true 2>/dev/null && break; sleep 6; done; done
  sleep 60; }

case "${1:-}" in
check)
  for h in a b c; do say "$h"
    rs $h 'echo "host=$(hostname) user=$(id -un)"; sudo -n true && echo "sudo: ok" || echo "sudo: NEEDS PASSWORD (see DOCUMENTATION 0.6)"; echo "internet: $(curl -sI -m 5 https://deb.debian.org | head -1)"; echo "model: $(tr -d "\0" < /proc/device-tree/model)"; echo "IBSS: $(/usr/sbin/iw list 2>/dev/null | grep -c "\* IBSS") (1 = onboard radio is fine)"; echo "batman-adv module: $(/usr/sbin/modinfo batman-adv 2>/dev/null | awk "/^version/{print \$2}")"'
  done ;;
1)
  for h in a b c; do say "phase 1 on $h"; sudo_script $h scripts/common/01-base-os.sh | tail -3; done
  reboot_wait a b c
  for h in a b c; do rs $h 'echo "$(hostname): wlan0 $(nmcli -t device status | grep wlan0 | cut -d: -f3), batctl $(/usr/sbin/batctl -v | cut -d" " -f2)"'; done ;;
2)
  for h in a b c; do say "phase 2 on $h ($(mip $h))"
    scp -q scripts/common/lnmesh-mesh.sh units/lnmesh-mesh.service "lnmesh-$h:/tmp/"
    sudo_script $h scripts/common/02-mesh.sh "$(mip $h)"
  done
  echo "waiting 30 s for neighbours"; sleep 30
  for h in a b c; do say "$h neighbours"; rs $h 'sudo batctl n | tail -n +3'; done
  rs a "ping -c 3 $MESH_B | tail -1; ping -c 3 $MESH_C | tail -1" ;;
3)
  say "A serves time"; sudo_script a scripts/gateway/03-chrony-server.sh; sudo_script a scripts/common/03-chrony-after-mesh.sh >/dev/null
  for h in b c; do say "$h follows A"; sudo_script $h scripts/offline/03-chrony-client.sh | grep -E '^\^' ; done
  rs a 'sudo chronyc clients | tail -n +3' ;;
4)
  say "Bitcoin Core on A"; sudo_script a scripts/gateway/04-bitcoind-install.sh
  PASS=$(rs a 'sudo cat /etc/lnmesh/rpcauth.txt' | awk '/^Your password:/{getline; print; exit}')
  [ -n "$PASS" ] || { echo "could not read the RPC password from A"; exit 1; }
  awk -v p="$PASS" '/^BTC_RPC_PASS=/{print "BTC_RPC_PASS=" p; next} {print}' hosts.env > hosts.env.tmp && mv hosts.env.tmp hosts.env; chmod 600 hosts.env
  echo "BTC_RPC_PASS recorded in hosts.env"
  scp -q units/bitcoind.service lnmesh-a:/tmp/
  sudo_script a scripts/gateway/04-bitcoind-config.sh
  say "block filters for Neutrino"; sudo_script a scripts/gateway/07-blockfilters.sh
  say "RPC from B over the mesh"
  rs b "curl -s -m 5 --user lnmesh:$PASS --data-binary '{\"jsonrpc\":\"1.0\",\"id\":\"t\",\"method\":\"getblockcount\",\"params\":[]}' http://$MESH_A:18443/"; echo ;;
5)
  source hosts.env; [ -n "$BTC_RPC_PASS" ] || { echo "run phase 4 first"; exit 1; }
  for h in a b c; do say "LND install on $h"; sudo_script $h scripts/common/05-lnd-install.sh | tail -1; scp -q units/lnd.service "lnmesh-$h:/tmp/"; done
  say "LND config: A bitcoind, B and C Neutrino"
  sudo_script a scripts/common/05-lnd-config.sh a "$MESH_A" bitcoind "$BTC_RPC_PASS" | tail -1
  sudo_script b scripts/common/05-lnd-config.sh b "$MESH_B" neutrino | tail -1
  sudo_script c scripts/common/05-lnd-config.sh c "$MESH_C" neutrino | tail -1
  say "mine 101 to A's wallet"
  rs a '[ -s /etc/lnmesh/mine.addr ] || lncli-mesh newaddress p2tr | jq -r .address | sudo tee /etc/lnmesh/mine.addr >/dev/null; mine 101; sleep 5; echo "A confirmed balance: $(lncli-mesh walletbalance | jq -r .confirmed_balance) sat"'
  for h in a b c; do pk=$(rs $h 'lncli-mesh getinfo | jq -r .identity_pubkey'); U=$(echo $h | tr a-z A-Z)
    awk -v k="PK_$U" -v v="$pk" '$0 ~ "^"k"=" {print k"="v; next} {print}' hosts.env > hosts.env.tmp && mv hosts.env.tmp hosts.env
    rs $h 'lncli-mesh getinfo | jq -c "{alias, synced_to_chain, block_height}"'; done
  echo "PK_A/B/C recorded in hosts.env" ;;
6.1)
  sudo_script a scripts/gateway/06-noforward.sh ;;
6.2)
  cat <<EOF
Replace the lnmesh-b and lnmesh-c entries in ~/.ssh/config with:

Host lnmesh-b-lan
  HostName $MGMT_B
  User $SSH_USER_B
Host lnmesh-c-lan
  HostName $MGMT_C
  User $SSH_USER_C
Host lnmesh-b
  HostName $MESH_B
  User $SSH_USER_B
  ProxyJump lnmesh-a
Host lnmesh-c
  HostName $MESH_C
  User $SSH_USER_C
  ProxyJump lnmesh-a

Then rerun: ./scripts/build.sh 6.2 test
EOF
  if [ "${2:-}" = test ]; then for h in b c; do rs $h 'echo "$(hostname) reached via $(echo $SSH_CONNECTION | cut -d" " -f1)"'; done; fi ;;
6.3)
  echo "Ethernet must already be unplugged from B and C. Continue? [y/N]"; read -r ans; [ "$ans" = y ] || exit 1
  for h in b c; do say "isolate $h"; sudo_script $h scripts/offline/06-isolate.sh "$HOME_ROUTER"; done ;;
status)
  set +e
  for h in a b c; do printf '%s: ' $h; rs $h 'echo "nbrs=$(( $(sudo batctl n | grep -c wlan0) - 1 )) chrony=$(chronyc -n sources | grep -E "^\^\*" | awk "{print \$2}") default=[$(ip route show default | cut -d" " -f3)] lnd=$(lncli-mesh getinfo 2>/dev/null | jq -c "[.synced_to_chain,.block_height,.num_active_channels]")"' 2>&1; done ;;
*) sed -n '2,16p' "$0"; exit 1 ;;
esac
