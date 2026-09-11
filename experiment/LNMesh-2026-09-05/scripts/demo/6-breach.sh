#!/usr/bin/env bash
# Demo 6: breach response. REGTEST ONLY. C restores a stale channel.db and
# force-closes B-C while B is down; B returns and takes the whole channel.
source "$(dirname "$0")/lib.sh"
echo "== Demo 6: breach response (regtest only)"
require_regtest
CDB=/var/lib/lnd/data/graph/regtest/channel.db
has_chan b c || { open_chan b c 1000000; mine 6; }; wait_active b c
show b; show c
CAP=$(q b "lncli-mesh listchannels | jq -r '.channels[] | select(.remote_pubkey==\"$PK_C\") | .capacity'")
echo ">> B-C capacity $CAP sat"

echo "== snapshot C's channel.db"
run c "sudo systemctl stop lnd"
run c "sudo cp $CDB /root/channel.db.stale && sudo ls -l /root/channel.db.stale"
run c "sudo systemctl start lnd"; wait_synced c; wait_active c b
echo "== advance the channel state (B pays C three times)"
for i in 1 2 3; do pay b c 50000 "advance state $i"; done
show b; show c
echo "== B goes away"
run b "sudo systemctl stop lnd"
echo "== C rewinds to the stale state and force-closes"
run c "sudo systemctl stop lnd"
run c "sudo cp /root/channel.db.stale $CDB && sudo chown lnd:lnd $CDB"
run c "sudo systemctl start lnd"; wait_synced c
run c "lncli-mesh listchannels | jq -c '.channels[] | {peer: .remote_pubkey[0:10], active, local_balance, remote_balance}'"
close_chan c b --force
sleep 5
STALE=$(q a "bcli getrawmempool | jq -r '.[0]'"); echo ">> A mempool holds stale commitment: $STALE"
mine 1; H_STALE=$(height); echo ">> stale commitment confirmed at height $H_STALE"
echo "== B returns"
run b "sudo systemctl start lnd"; wait_synced b
for i in $(seq 1 30); do q a 'bcli getrawmempool | jq -e "length>0" >/dev/null' && break; sleep 3; done
run b "sudo journalctl -u lnd --since -10min --no-pager | grep -iE 'breached|revoked state|justice|Detected spend' | cut -c33-220 | head -8"
JUST=$(q a "bcli getrawmempool | jq -r '.[0]'"); echo ">> A mempool holds justice tx: $JUST"
mine 1; H_JUST=$(height); sleep 5
echo ">> justice tx confirmed at height $H_JUST (gap $((H_JUST - H_STALE)) block)"
run b "lncli-mesh closedchannels | jq -c '.channels[] | select(.close_type==\"BREACH_CLOSE\") | {peer: .remote_pubkey[0:10], close_type, closing_tx_hash, settled_balance, close_height}'"
show b; show c
echo ">> B wallet after breach: $(wallet b) sat. Capacity was $CAP sat."

echo "== cleanup: reset C (section 8.3), close A-C from A, refund and reopen"
if has_chan a c; then close_chan a c --force; mine 1; mine 1008; for i in 1 2 3 4 5 6; do sleep 5; q a 'bcli getrawmempool | jq -e "length>0" >/dev/null' && break; done; mine 1; fi
run c "sudo systemctl stop lnd && sudo rm -rf /var/lib/lnd/data /var/lib/lnd/logs && sudo systemctl start lnd"; wait_synced c
NEWPK=$(q c "lncli-mesh getinfo | jq -r .identity_pubkey"); echo ">> C new identity $NEWPK"
awk -v pk="$NEWPK" '/^PK_C=/{print "PK_C=" pk; next} {print}' hosts.env > hosts.env.tmp && mv hosts.env.tmp hosts.env; PK_C=$NEWPK
addr=$(q c "lncli-mesh newaddress p2tr | jq -r .address"); run a "lncli-mesh sendcoins --addr $addr --amt 2000000 --sat_per_vbyte 1"; mine 6
open_chan b c 1000000; open_chan a c 1000000 400000; mine 6
wait_active b c && wait_active a c && echo "B-C and A-C open again"
for h in a b c; do show $h; done
done_msg
