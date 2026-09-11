"""Recorded regtest demonstrations using only stock Bitcoin Core and LND CLIs."""
from __future__ import annotations
import argparse,base64,concurrent.futures,datetime as dt,json,shlex,time
from pathlib import Path
from runner import Runner,BASE,EVIDENCE,MESH,append_event,utc

def outcome(name, **values):
    record={"name":name,"recorded_utc":utc(),**values}
    with (EVIDENCE/'outcomes.jsonl').open('a',encoding='utf-8') as f:
        f.write(json.dumps(record)+'\n')
    print('OUTCOME '+name+' recorded '+record['recorded_utc'],flush=True)
    return record

class Experiment:
    def __init__(self):
        self.r=Runner('mesh',verbose='summary')
        self.keys={}

    def rpc(self,h,*args,bitcoin=False,label=None,timed=False,timeout=90):
        binary='/usr/local/bin/bcli' if bitcoin else '/usr/local/bin/lncli-mesh'
        command=shlex.join((["/usr/local/bin/lnmesh-measure"] if timed else [])+[binary]+list(map(str,args)))
        return self.r.json(h,command,label=label or args[0],timeout=timeout)

    def load_keys(self):
        for h in 'abc':
            info=self.rpc(h,'getinfo',label='identify-regtest')
            assert info['chains']==[{'chain':'bitcoin','network':'regtest'}],info['chains']
            self.keys[h]=info['identity_pubkey']
        assert self.rpc('a','getblockchaininfo',bitcoin=True)['chain']=='regtest'
        (EVIDENCE/'node-public-keys.json').write_text(json.dumps(self.keys,indent=2),encoding='utf-8')

    def wait(self,h,command,predicate,*,label,seconds=120):
        deadline=time.monotonic()+seconds
        while True:
            value=self.rpc(h,*command,label=label)
            if predicate(value): return value
            if time.monotonic()>deadline: raise TimeoutError(label)
            time.sleep(2)

    def synced(self,hosts='abc'):
        height=self.rpc('a','getblockcount',bitcoin=True)
        for h in hosts:
            self.wait(h,['getinfo'],lambda j:j['synced_to_chain'] and j['block_height']==height,label='wait-chain-sync')
        return height

    def mine(self,n):
        addr=(EVIDENCE/'mining-address.txt').read_text().strip()
        out=self.rpc('a','generatetoaddress',n,addr,bitcoin=True,timed=True,label=f'mine-{n}-blocks',timeout=180)
        self.synced()
        return out

    def channels(self,h): return self.rpc(h,'listchannels')['channels']
    def wallet(self,h): return int(self.rpc(h,'walletbalance')['confirmed_balance'])
    def channel(self,h,peer): return next((c for c in self.channels(h) if c['remote_pubkey']==self.keys[peer]),None)

    def snapshot(self,name):
        state={h:{'wallet':self.rpc(h,'walletbalance'),'channelbalance':self.rpc(h,'channelbalance'),'channels':self.channels(h),'pending':self.rpc(h,'pendingchannels'),'info':self.rpc(h,'getinfo')} for h in 'abc'}
        outcome(name,state=state)
        return state

    def active(self,h,peer):
        return self.wait(h,['listchannels'],lambda j:any(c['remote_pubkey']==self.keys[peer] and c['active'] for c in j['channels']),label=f'wait-active-{h}-{peer}')

    def open(self,h,peer,amount=1000000,push=0):
        existing=self.channel(h,peer)
        if existing: raise RuntimeError(f'Channel {h}-{peer} already exists; refusing duplicate experiment')
        self.r.run(h,shlex.join(['/usr/local/bin/lncli-mesh','connect',self.keys[peer]+'@'+MESH[peer]+':9735']),label=f'connect-{h}-{peer}',check=False)
        args=['openchannel','--node_key',self.keys[peer],'--local_amt',str(amount),'--private','--sat_per_vbyte','1']
        if push: args+=['--push_amt',str(push)]
        opened=self.rpc(h,*args,timed=True,label=f'open-{h}-{peer}')
        txid=opened['result']['funding_txid']
        mempool=self.rpc('a','getrawmempool',bitcoin=True,label='funding-mempool')
        assert txid in mempool,(txid,mempool)
        self.mine(6)
        self.active(h,peer); self.active(peer,h)
        chan=self.channel(h,peer)
        tx=self.rpc('a','getrawtransaction',txid,1,bitcoin=True)
        outcome('channel-open',payer=h,peer=peer,timing=opened,channel=chan,transaction=tx)
        return chan

    def bootstrap(self):
        src=base64.b64encode((BASE/'scripts/measure.py').read_bytes()).decode()
        for h in 'abc':
            self.r.run(h,f"set -euo pipefail\nprintf %s {src} | base64 -d > /usr/local/bin/lnmesh-measure\nchmod 0755 /usr/local/bin/lnmesh-measure",label='install-measurement-helper')
        self.load_keys()
        height=self.rpc('a','getblockcount',bitcoin=True)
        assert height==0, 'Bootstrap requires a fresh regtest chain'
        self.snapshot('empty-offline-baseline')
        addr=self.rpc('a','newaddress','p2tr')['address']
        (EVIDENCE/'mining-address.txt').write_text(addr,encoding='utf-8')
        self.mine(101)
        outcome('gateway-initial-mining',height=101,gateway_wallet_sat=self.wallet('a'),leaf_wallets_sat={h:self.wallet(h) for h in 'bc'})

    def funding(self):
        self.load_keys(); self.synced()
        assert self.wallet('b')==0 and self.wallet('c')==0
        self.open('a','b',push=400000)
        b=self.channel('b','a')
        assert self.wallet('b')==0 and int(b['local_balance'])==400000
        outcome('inbound-balance-with-zero-onchain',onchain_sat=0,channel_local_sat=int(b['local_balance']),channel_point=b['channel_point'])
        funding=[]
        for h in 'bc':
            addr=self.rpc(h,'newaddress','p2tr')['address']
            tx=self.rpc('a','sendcoins','--addr',addr,'--amt','2000000','--sat_per_vbyte','1',timed=True,label=f'fund-{h}')
            funding.append({'leaf':h,'address':addr,'timing':tx})
        self.rpc('a','getrawmempool',bitcoin=True)
        self.mine(6)
        balances={h:self.wallet(h) for h in 'bc'}
        assert balances=={'b':2000000,'c':2000000},balances
        outcome('offline-onchain-funding',funding=funding,confirmed_balances_sat=balances)
        self.open('b','c')
        self.open('a','c',push=400000)
        self.snapshot('funded-triangle')

    def inspect(self):
        self.r.run('b','lncli-mesh help payinvoice; lncli-mesh help closechannel',label='cli-capabilities')

    def pay(self,payer,payee,amount,condition,index=1):
        inv=self.rpc(payee,'addinvoice','--amt',amount,'--memo',f'{condition} {payer}-{payee} {index}')
        paid=self.rpc(payer,'payinvoice','--force','--json','--timeout','30s',inv['payment_request'],timed=True,label=f'payment-{condition}-{payer}-{payee}-{index}',timeout=45)
        payment=paid['result'][-1] if isinstance(paid['result'],list) else paid['result']
        assert payment['status']=='SUCCEEDED',payment
        received=self.rpc(payee,'lookupinvoice',payment['payment_hash'])
        assert received['settled'] and int(received['amt_paid_sat'])==amount,received
        return outcome('payment',condition=condition,index=index,payer=payer,payee=payee,amount_sat=amount,timing=paid,invoice_settled=True)

    def payments(self):
        self.load_keys();self.synced()
        for payer,payee in [('b','c'),('b','a'),('a','b')]:
            for i in range(1,31): self.pay(payer,payee,10000,'chain-running',i)
        self.snapshot('after-payment-series')

    def close(self,h,peer,force=False):
        c=self.channel(h,peer)
        assert c,c
        before=self.wallet(h)
        args=['closechannel','--chan_point',c['channel_point']]
        args+=['--force'] if force else ['--sat_per_vbyte','1']
        closed=self.rpc(h,*args,timed=True,label='force-close' if force else 'cooperative-close')
        mempool=self.rpc('a','getrawmempool',bitcoin=True)
        assert mempool,'closing transaction not in mempool'
        transactions=[self.rpc('a','getrawtransaction',tx,1,bitcoin=True) for tx in mempool]
        spenders=[tx for tx in transactions if any(v.get('txid')==c['channel_point'].split(':')[0] and v.get('vout')==int(c['channel_point'].split(':')[1]) for v in tx['vin'])]
        assert len(spenders)==1,spenders
        closing_txid=spenders[0]['txid']
        self.mine(1)
        if force:
            pend=self.wait(h,['pendingchannels'],lambda j:any(x['channel']['channel_point']==c['channel_point'] and x['maturity_height']>0 for x in j['pending_force_closing_channels']),label='wait-force-close-maturity')
            item=next(x for x in pend['pending_force_closing_channels'] if x['channel']['channel_point']==c['channel_point'])
            height=self.rpc('a','getblockcount',bitcoin=True)
            remaining=int(item['maturity_height'])-height
            outcome('force-close-timelock',pending=item,observed_height=height,remaining_blocks=remaining)
            assert remaining==1008,(remaining,item)
            self.mine(remaining)
            # Wallet rescan and sweeper scheduling are asynchronous after accelerated mining.
            end=time.monotonic()+120
            sweep=[]
            while time.monotonic()<end:
                pool=self.rpc('a','getrawmempool',bitcoin=True,label='wait-sweep-mempool')
                sweep=[self.rpc('a','getrawtransaction',tx,1,bitcoin=True) for tx in pool]
                sweep=[tx for tx in sweep if any(v.get('txid')==closing_txid for v in tx['vin'])]
                if sweep: break
                time.sleep(2)
            assert sweep,'sweep not observed'
            self.mine(1)
            self.wait(h,['pendingchannels'],lambda j:not any(x['channel']['channel_point']==c['channel_point'] for x in j['pending_force_closing_channels']),label='force-close-fully-resolved')
        else:
            sweep=[]
        hist=self.wait(h,['closedchannels'],lambda j:any(x['channel_point']==c['channel_point'] for x in j['channels']),label='closed-channel-history')
        entry=next(x for x in hist['channels'] if x['channel_point']==c['channel_point'])
        after=self.wallet(h)
        assert after>before,(before,after)
        outcome('force-close' if force else 'cooperative-close',node=h,peer=peer,channel=c,timing=closed,closing_transaction=spenders[0],sweep_transactions=sweep,closed_channel=entry,wallet_before_sat=before,wallet_after_sat=after,wallet_delta_sat=after-before)

    def closes(self):
        self.load_keys();self.synced()
        self.close('b','a')
        self.close('b','c',force=True)
        self.open('a','b',push=400000)
        self.open('b','c')
        self.snapshot('after-close-reopen')

    def baseline(self):
        self.load_keys();self.synced()
        for i in range(1,31): self.pay('b','c',5000,'baseline-chain-running',i)
        height=self.rpc('a','getblockcount',bitcoin=True)
        self.r.run('a',"set -euo pipefail\nsystemd-run --unit=lnmesh-chain-restore --on-active=5min /bin/bash -c 'systemctl start bitcoind; systemctl restart lnd'\nsystemctl stop bitcoind\ntest \"$(systemctl is-active bitcoind || true)\" = inactive\ndate --iso-8601=ns --utc",label='stop-chain-for-baseline')
        try:
            for i in range(1,31): self.pay('b','c',5000,'chain-stopped',i)
            for h in 'bc':
                info=self.rpc(h,'getinfo',label='leaf-info-with-chain-stopped')
                assert info['block_height']==height
            self.r.run('a',"test \"$(systemctl is-active bitcoind || true)\" = inactive; date --iso-8601=ns --utc",label='chain-still-stopped')
            outcome('chain-stopped-baseline',payments=30,unchanged_height=height)
        finally:
            self.r.run('a','set -euo pipefail\nsystemctl start bitcoind\ntimeout 60 bash -c "until bcli getblockchaininfo >/dev/null 2>&1; do sleep 1; done"\nsystemctl restart lnd\ntimeout 90 bash -c "until lncli-mesh getinfo >/dev/null 2>&1; do sleep 1; done"\nsystemctl stop lnmesh-chain-restore.timer',label='restore-chain-and-gateway-lnd',timeout=180)
        self.synced(); self.active('a','b'); self.active('a','c'); self.active('b','c')
        self.snapshot('after-baseline-recovery')

    def links(self):
        # Serialize traffic generators so bandwidth samples do not compete with each other.
        for src in 'abc':
            for dst in 'abc':
                if src==dst:continue
                result=self.r.run(src,f'ping -D -n -I bat0 -c 100 -i 0.05 -W 2 {MESH[dst]}',label=f'rtt-{src}-{dst}',timeout=20)
                outcome('ping-series',source=src,destination=dst,event=result['event'])
        for src,dst in [('b','a'),('c','a'),('b','c')]:
            for i in range(1,4):
                self.r.run(dst,f'systemd-run --unit=lnmesh-iperf-{src}-{dst}-{i} --property=RuntimeMaxSec=30 /usr/bin/iperf3 -s -1 -B {MESH[dst]} -J',label='start-iperf-server')
                result=self.r.json(src,f'iperf3 -c {MESH[dst]} -B {MESH[src]} -t 10 -J --connect-timeout 5000',label=f'throughput-{src}-{dst}-{i}',timeout=25)
                assert 'error' not in result,result
                outcome('iperf-series',source=src,destination=dst,index=i,result=result)

    def xrpc(self,*args,timed=False,label='breach-node-rpc'):
        command=shlex.join((['/usr/local/bin/lnmesh-measure'] if timed else [])+['/usr/local/bin/lncli-breach']+list(map(str,args)))
        return self.r.json('c',command,label=label)

    def breach(self):
        self.load_keys();self.synced()
        self.r.run('c',(BASE/'scripts/create-breach-node.sh').read_text(),label='create-disposable-breach-node',timeout=150)
        x=self.xrpc('getinfo')
        assert x['chains']==[{'chain':'bitcoin','network':'regtest'}]
        xkey=x['identity_pubkey']
        self.r.run('b',f'lncli-mesh connect {xkey}@10.10.0.3:9736',label='connect-breach-node')
        opening=self.rpc('b','openchannel','--node_key',xkey,'--local_amt','500000','--push_amt','200000','--private','--sat_per_vbyte','1',timed=True,label='open-breach-channel')
        self.mine(6)
        self.wait('b',['listchannels'],lambda j:any(c['remote_pubkey']==xkey and c['active'] for c in j['channels']),label='breach-channel-active')
        ch=next(c for c in self.xrpc('listchannels')['channels'] if c['remote_pubkey']==self.keys['b'])
        cp=ch['channel_point']
        assert int(ch['local_balance'])==200000
        self.r.run('c',"set -euo pipefail\nsystemctl stop lnd-breach\ninstall -d -m 0700 /var/backups/lnmesh/breach\ncp --reflink=auto /var/lib/lnd-breach/data/graph/regtest/channel.db /var/backups/lnmesh/breach/channel.stale.db\nsha256sum /var/backups/lnmesh/breach/channel.stale.db\nsystemctl start lnd-breach\ntimeout 90 bash -c 'until lncli-breach getinfo >/dev/null 2>&1; do sleep 1; done'",label='snapshot-stale-channel-state')
        self.wait('b',['listchannels'],lambda j:any(c['channel_point']==cp and c['active'] for c in j['channels']),label='breach-channel-reconnected')
        # The would-be cheater sends money away, making its stale balance larger.
        for i in range(1,4):
            inv=self.rpc('b','addinvoice','--amt','25000','--memo',f'breach-state-advance-{i}')
            paid=self.xrpc('payinvoice','--json','--force','--timeout','30s',inv['payment_request'],timed=True,label=f'advance-breach-state-{i}')
            result=paid['result'][-1] if isinstance(paid['result'],list) else paid['result']
            assert result['status']=='SUCCEEDED'
            outcome('breach-state-payment',index=i,timing=paid)
        advanced=next(c for c in self.xrpc('listchannels')['channels'] if c['channel_point']==cp)
        assert int(advanced['local_balance'])==125000,advanced
        before=self.wallet('b')
        outcome('breach-state-before-rewind',stale=ch,current=advanced,stale_balance_advantage_sat=75000,opening=opening,victim_wallet_before_sat=before)
        self.r.run('b','systemctl stop lnd; date --iso-8601=ns --utc',label='victim-offline')
        try:
            self.r.run('c',"set -euo pipefail\nsystemctl stop lnd-breach\ncp --reflink=auto /var/lib/lnd-breach/data/graph/regtest/channel.db /var/backups/lnmesh/breach/channel.latest.db\ncp /var/backups/lnmesh/breach/channel.stale.db /var/lib/lnd-breach/data/graph/regtest/channel.db\nchown lnd:lnd /var/lib/lnd-breach/data/graph/regtest/channel.db\nsha256sum /var/backups/lnmesh/breach/channel.stale.db /var/lib/lnd-breach/data/graph/regtest/channel.db\nsystemctl start lnd-breach\ntimeout 90 bash -c 'until lncli-breach getinfo >/dev/null 2>&1; do sleep 1; done'",label='restore-stale-channel-state')
            stale=next(c for c in self.xrpc('listchannels')['channels'] if c['channel_point']==cp)
            assert int(stale['local_balance'])==200000 and not stale['active'],stale
            closing=self.xrpc('closechannel','--chan_point',cp,'--force',timed=True,label='broadcast-revoked-commitment')
            pool=self.rpc('a','getrawmempool',bitcoin=True)
            txs=[self.rpc('a','getrawtransaction',tx,1,bitcoin=True) for tx in pool]
            revoked=next(t for t in txs if any(v.get('txid')==cp.split(':')[0] and v.get('vout')==int(cp.split(':')[1]) for v in t['vin']))
            # Mine directly because the victim is deliberately stopped.
            addr=(EVIDENCE/'mining-address.txt').read_text().strip()
            self.rpc('a','generatetoaddress',1,addr,bitcoin=True,timed=True,label='confirm-revoked-commitment')
            revoked_height=self.rpc('a','getblockcount',bitcoin=True)
            outcome('revoked-commitment-confirmed',transaction=revoked,height=revoked_height,timing=closing,stale_channel=stale)
        finally:
            self.r.run('b','systemctl start lnd; timeout 90 bash -c "until lncli-mesh getinfo >/dev/null 2>&1; do sleep 1; done"; date --iso-8601=ns --utc',label='victim-return',timeout=120)
        self.synced()
        end=time.monotonic()+120;justice=[]
        while time.monotonic()<end:
            pool=self.rpc('a','getrawmempool',bitcoin=True,label='await-justice')
            txs=[self.rpc('a','getrawtransaction',tx,1,bitcoin=True) for tx in pool]
            justice=[t for t in txs if any(v.get('txid')==revoked['txid'] for v in t['vin'])]
            if justice:break
            time.sleep(2)
        assert justice,'No justice transaction observed'
        self.mine(1)
        justice_height=self.rpc('a','getblockcount',bitcoin=True)
        history=self.wait('b',['closedchannels'],lambda j:any(c['channel_point']==cp and c['close_type']=='BREACH_CLOSE' for c in j['channels']),label='verify-breach-close')
        after=self.wallet('b')
        victim_entry=next(c for c in history['channels'] if c['channel_point']==cp)
        self.r.run('b',"journalctl -u lnd --since '15 minutes ago' --no-pager -o short-iso-precise | grep -iE 'breach|justice|revoked' | tail -60",label='breach-arbiter-log')
        badwallet=self.xrpc('walletbalance')
        assert int(badwallet['confirmed_balance'])==0
        assert after>before
        outcome('breach-response',victim='b',cheater='disposable-c',channel_point=cp,capacity_sat=500000,revoked_transaction=revoked,justice_transactions=justice,revoked_height=revoked_height,justice_height=justice_height,block_gap=justice_height-revoked_height,victim_closed_channel=victim_entry,victim_wallet_before_sat=before,victim_wallet_after_sat=after,victim_wallet_delta_sat=after-before,cheater_wallet=badwallet)
        self.r.run('c','systemctl stop lnd-breach; systemctl is-active lnd; date --iso-8601=ns --utc',label='quarantine-disposable-breach-node')
        self.active('a','b');self.active('a','c');self.active('b','c')
        self.snapshot('after-breach-main-triangle')


def main():
    p=argparse.ArgumentParser();p.add_argument('phase',choices=['bootstrap','funding','inspect','payments','closes','baseline','links','breach'])
    ns=p.parse_args();getattr(Experiment(),ns.phase)()

if __name__=='__main__':main()
