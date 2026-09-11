"""Validate the completed dataset and package the fresh run without wallet files."""
import ast,collections,csv,datetime as dt,hashlib,importlib.metadata,json,sys,zipfile
from pathlib import Path
from runner import BASE,EVIDENCE,utc
sys.path.insert(0,str(BASE/'.python-deps'))
from pypdf import PdfReader

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    d=json.loads((BASE/'report/analysis.json').read_text())
    rows=list(csv.DictReader((BASE/'report/payments.csv').open()))
    planned=[r for r in rows if r['condition']!='post-reboot-functional-check']
    assert len(planned)==150 and len(rows)==151
    assert len({r['payment_hash'] for r in rows})==151
    assert all(r['status']=='SUCCEEDED' and r['invoice_settled']=='True' and r['hops']=='1' and r['attempts']=='1' and r['fee_msat']=='0' for r in rows)
    assert len(d['pings'])==6 and sum(r['received'] for r in d['pings'])==600
    assert len(d['iperf'])==9
    assert len(d['evidence_hash_mismatches'])==4 and not d['events_unfinished']
    p=BASE/'report/LNMesh-research-writeup.pdf';pdf=PdfReader(p)
    assert len(pdf.pages)==17
    for page in pdf.pages:
        text=page.extract_text();assert len(text)>500 and '\ufffd' not in text
    for p in sorted(BASE.glob('*.py'))+sorted((BASE/'scripts').glob('*.py')):
        ast.parse(p.read_text(encoding='utf-8'),filename=str(p))
    dependencies={name:importlib.metadata.version(name) for name in ['reportlab','matplotlib','markdown','pypdf']}
    (BASE/'requirements-report.txt').write_text('\n'.join(f'{k}=={v}' for k,v in dependencies.items())+'\n',encoding='utf-8',newline='\n')
    audit=dict(checked_utc=utc(),planned_payments=150,additional_functional_payments=1,breach_state_advancing_payments=3,unique_regular_payment_hashes=151,all_regular_payments_settled=True,all_regular_routes_one_hop=True,all_regular_payments_one_attempt=True,all_regular_fees_zero=True,ping_packets_received=600,tcp_trials=9,pdf_pages=17,pdf_visual_review='All 17 rendered pages inspected; modified pages rechecked after final edits.',report_dependencies=dependencies,remote_event_count=d['events_finished'],nonzero_remote_events=len(d['events_failed']),unmatched_start_records=len(d['events_unfinished']),known_early_stdout_hash_mismatches=d['evidence_hash_mismatches'],local_execution_notes=['One inline PowerShell invocation of a final read-only disposable-node verifier failed local quoting before SSH; the check was rerun successfully from supplement.py.','The final launcher was syntax-checked; its complete sequence was not replayed on freshly erased Pis.'])
    (EVIDENCE/'delivery-audit.json').write_text(json.dumps(audit,indent=2),encoding='utf-8',newline='\n')
    included=[p for p in BASE.iterdir() if p.is_file() and (p.suffix in ['.py','.ps1','.md'] or p.name in ['.gitignore','requirements-report.txt'])]
    for folder in ['scripts','evidence','report']:
        included += [p for p in (BASE/folder).rglob('*') if p.is_file() and not {'__pycache__','qa'}&set(p.relative_to(BASE).parts)]
    included=sorted(set(included))
    # This bundle contains only textual evidence and report assets, never host credentials.
    forbidden={'.macaroon','.db','.key','.pem'}
    assert not any(p.suffix.lower() in forbidden for p in included)
    private_markers=[b'-----BEGIN OPENSSH PRIVATE KEY-----',b'-----BEGIN RSA PRIVATE KEY-----']
    for p in included:
        if p.suffix in ['.txt','.json','.jsonl','.sh','.py','.ps1','.md']:
            raw=p.read_bytes();assert not any(marker in raw for marker in private_markers if p.name!='package_results.py'),str(p)
    manifest=BASE/'SHA256SUMS.txt'
    manifest.write_text(''.join(f'{sha(p)}  {p.relative_to(BASE).as_posix()}\n' for p in included),encoding='utf-8',newline='\n')
    target=BASE/'LNMesh-experiment-2026-09-07.zip'
    with zipfile.ZipFile(target,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in included+[manifest]:z.write(p,'LNMesh-experiment-2026-09-07/'+p.relative_to(BASE).as_posix())
    with zipfile.ZipFile(target) as z:
        assert z.testzip() is None
        for p in included:
            name='LNMesh-experiment-2026-09-07/'+p.relative_to(BASE).as_posix()
            assert hashlib.sha256(z.read(name)).hexdigest()==sha(p)
    checksum=sha(target)
    (BASE/(target.name+'.sha256')).write_text(checksum+'  '+target.name+'\n',encoding='ascii')
    print(json.dumps(dict(bundle=str(target),files=len(included)+1,bytes=target.stat().st_size,sha256=checksum,pdf_pages=len(pdf.pages),audit=audit),indent=2))

if __name__=='__main__':main()
