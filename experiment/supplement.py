"""Read-only transaction proof and local provenance checks after live tests."""
import ast,decimal,hashlib,json,platform,shlex,sys
from pathlib import Path
from experiment import Experiment,outcome
from runner import BASE,EVIDENCE,utc

def main():
    e=Experiment()
    records=[json.loads(x) for x in (EVIDENCE/'outcomes.jsonl').read_text().splitlines()]
    breach=next(x for x in reversed(records) if x['name']=='breach-response')
    revoked=e.rpc('a','getrawtransaction',breach['revoked_transaction']['txid'],1,bitcoin=True,label='verify-confirmed-revoked-transaction')
    justice=e.rpc('a','getrawtransaction',breach['justice_transactions'][0]['txid'],1,bitcoin=True,label='verify-confirmed-justice-transaction')
    def sats(x):return int(decimal.Decimal(str(x))*100000000)
    spent=[i['vout'] for i in justice['vin'] if i['txid']==revoked['txid']]
    principal=[o['n'] for o in revoked['vout'] if sats(o['value'])>330]
    assert set(spent)==set(principal) and len(spent)==2
    assert revoked['confirmations']>0 and justice['confirmations']>0
    total_in=sum(sats(revoked['vout'][i]['value']) for i in spent)
    total_out=sum(sats(o['value']) for o in justice['vout'])
    assert total_out==breach['victim_wallet_delta_sat']
    outcome('breach-transaction-proof',revoked_txid=revoked['txid'],justice_txid=justice['txid'],revoked_blockhash=revoked['blockhash'],justice_blockhash=justice['blockhash'],revoked_confirmations=revoked['confirmations'],justice_confirmations=justice['confirmations'],spent_revoked_output_indices=spent,principal_output_indices=principal,principal_input_sat=total_in,justice_output_sat=total_out,justice_fee_sat=total_in-total_out)
    e.r.run('c','set -e\ntest "$(systemctl is-active lnd-breach || true)" = inactive\ntest "$(systemctl is-enabled lnd-breach || true)" != enabled\nsystemctl is-active lnd',label='disposable-node-remains-stopped')
    checks=[]
    for p in sorted(BASE.glob('*.py'))+sorted((BASE/'scripts').glob('*.py')):
        ast.parse(p.read_text(encoding='utf-8'),filename=str(p));checks.append(str(p.relative_to(BASE)))
    scripts=sorted((BASE/'scripts').glob('*.sh'))
    command='set -e\n'+'\n'.join('bash -n -c '+shlex.quote(p.read_text()) for p in scripts)+'\nprintf "PASS Bash syntax for '+str(len(scripts))+' scripts\\n"'
    e.r.run('a',command,root=False,label='source-bash-syntax')
    archive=Path(r'C:\Users\bmlan\Desktop\LNMesh-2026-09-05.tar.gz')
    provenance=dict(recorded_utc=utc(),controller_platform=platform.platform(),controller_python=sys.version,controller_timezone='America/Chicago',archive=dict(filename=archive.name,bytes=archive.stat().st_size,sha256=hashlib.sha256(archive.read_bytes()).hexdigest()),python_ast_checked=checks,bash_syntax_checked=[str(p.relative_to(BASE)) for p in scripts])
    (EVIDENCE/'provenance.json').write_text(json.dumps(provenance,indent=2),encoding='utf-8',newline='\n')
    print(json.dumps(provenance,indent=2))

if __name__=='__main__':main()
