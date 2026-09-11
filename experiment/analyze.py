"""Derive descriptive statistics and shareable tables from recorded evidence."""
import collections,csv,datetime as dt,hashlib,json,math,re,statistics,sys
from pathlib import Path
from runner import BASE,EVIDENCE

def read_jsonl(p):return [json.loads(line) for line in p.read_text(encoding='utf-8').splitlines() if line.strip()]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def percentile(values,p):
    s=sorted(values);i=(len(s)-1)*p/100;lo=math.floor(i);hi=math.ceil(i)
    return s[lo]+(s[hi]-s[lo])*(i-lo)
def stats(v):
    return dict(n=len(v),min=min(v),median=statistics.median(v),mean=statistics.mean(v),p95=percentile(v,95),max=max(v),sd=statistics.stdev(v) if len(v)>1 else 0)
def csvwrite(path,rows):
    if not rows:return
    with path.open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)

def main(quiet=False):
    report=BASE/'report';report.mkdir(exist_ok=True)
    outcomes=read_jsonl(EVIDENCE/'outcomes.jsonl')
    events=read_jsonl(EVIDENCE/'events.jsonl')
    finished=[e for e in events if e['state']=='finished']
    groups=collections.defaultdict(list);payments=[]
    for o in outcomes:
        if o['name']!='payment':continue
        p=o['timing']['result'];p=p[-1] if isinstance(p,list) else p
        htlcs=p['htlcs']
        row=dict(condition=o['condition'],payer=o['payer'],payee=o['payee'],trial=o['index'],amount_sat=o['amount_sat'],started_utc=o['timing']['started_utc'],ended_utc=o['timing']['ended_utc'],local_cli_elapsed_ms=o['timing']['elapsed_ns']/1e6,htlc_elapsed_ms=(max(int(h['resolve_time_ns']) for h in htlcs)-min(int(h['attempt_time_ns']) for h in htlcs))/1e6,status=p['status'],fee_msat=int(p['fee_msat']),attempts=len(htlcs),hops=max(len(h['route']['hops']) for h in htlcs),payment_hash=p['payment_hash'],invoice_settled=o['invoice_settled'])
        payments.append(row);groups[(o['condition'],o['payer'],o['payee'])].append(row)
    summary=[]
    for (condition,payer,payee),rows in groups.items():
        summary.append(dict(condition=condition,payer=payer,payee=payee,amount_sat=rows[0]['amount_sat'],successes=sum(r['status']=='SUCCEEDED' and r['invoice_settled'] for r in rows),cli_ms=stats([r['local_cli_elapsed_ms'] for r in rows]),htlc_ms=stats([r['htlc_elapsed_ms'] for r in rows]),start_utc=rows[0]['started_utc'],end_utc=rows[-1]['ended_utc']))
    pings=[]
    for o in outcomes:
        if o['name']!='ping-series':continue
        raw=(EVIDENCE/o['event']['stdout_file']).read_text(encoding='utf-8')
        values=[float(x) for x in re.findall(r'time=([0-9.]+) ms',raw)]
        packet=re.search(r'(\d+) packets transmitted, (\d+) received, ([0-9.]+)% packet loss',raw)
        assert packet,raw
        pings.append(dict(source=o['source'],destination=o['destination'],transmitted=int(packet[1]),received=int(packet[2]),loss_pct=float(packet[3]),rtt_ms=stats(values),values_ms=values,event_id=o['event']['id']))
    iperf=[]
    for o in outcomes:
        if o['name']!='iperf-series':continue
        r=o['result'];iperf.append(dict(source=o['source'],destination=o['destination'],trial=o['index'],start_epoch_seconds=r['start']['timestamp']['timesecs'],receiver_mbps=r['end']['sum_received']['bits_per_second']/1e6,sender_mbps=r['end']['sum_sent']['bits_per_second']/1e6,receiver_bytes=r['end']['sum_received']['bytes'],receiver_seconds=r['end']['sum_received']['seconds'],retransmits=r['end']['sum_sent']['retransmits']))
    iperf_group=[]
    for src,dst in [('b','a'),('c','a'),('b','c')]:
        rows=[r for r in iperf if r['source']==src and r['destination']==dst]
        if rows:iperf_group.append(dict(source=src,destination=dst,receiver_mbps=stats([r['receiver_mbps'] for r in rows]),total_retransmits=sum(r['retransmits'] for r in rows)))
    audit=[]
    for e in finished:
        mismatch=[]
        for kind in ['script','stdout','stderr']:
            p=EVIDENCE/e[kind+'_file']
            # Early Windows writes translated LF to CRLF after text hashing.
            if not p.exists() or (sha(p)!=e[kind+'_sha256'] and hashlib.sha256(p.read_bytes().replace(b'\r\n',b'\n')).hexdigest()!=e[kind+'_sha256']):mismatch.append(kind)
        if mismatch:audit.append(dict(id=e['id'],label=e['label'],host=e['host'],mismatched=mismatch))
    ended={e['id'] for e in finished}
    data=dict(generated_utc=dt.datetime.now(dt.timezone.utc).isoformat(),payment_summary=summary,pings=pings,iperf=iperf,iperf_summary=iperf_group,events_finished=len(finished),events_unfinished=[e for e in events if e['state']=='started' and e['id'] not in ended],events_failed=[{k:e[k] for k in ['id','label','host','returncode','started_utc','ended_utc']} for e in finished if e['returncode']],evidence_hash_mismatches=audit,outcomes=outcomes)
    (report/'analysis.json').write_text(json.dumps(data,indent=2),encoding='utf-8')
    csvwrite(report/'payments.csv',payments)
    csvwrite(report/'throughput.csv',iperf)
    csvwrite(report/'ping_summary.csv',[{**{k:v for k,v in r.items() if k not in ['rtt_ms','values_ms']},**{'rtt_'+k:v for k,v in r['rtt_ms'].items()}} for r in pings])
    csvwrite(report/'timeline.csv',[{k:e[k] for k in ['id','label','host','transport','started_utc','ended_utc','elapsed_seconds','returncode','script_file','stdout_file','stderr_file']} for e in finished])
    if not quiet:print(json.dumps({k:data[k] for k in ['payment_summary','iperf_summary','events_finished','events_unfinished','events_failed','evidence_hash_mismatches']},indent=2))

if __name__=='__main__':main()
