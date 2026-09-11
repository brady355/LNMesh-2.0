"""Create a one-page digest from the frozen experimental analysis."""
import datetime as dt,hashlib,html,json
from pathlib import Path
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate,Paragraph,Spacer,Table,TableStyle

BASE=Path(__file__).resolve().parent
OUT=BASE/'report'
source=OUT/'analysis.json'
d=json.loads(source.read_text(encoding='utf-8'))
def last(name):return next(o for o in reversed(d['outcomes']) if o['name']==name)
def commas(value):return f'{value:,.0f}'
planned=[p for p in d['payment_summary'] if p['condition']!='post-reboot-functional-check']
assert len(planned)==5 and sum(p['successes'] for p in planned)==150
assert all(p['successes']==p['cli_ms']['n']==30 for p in planned)
breach=last('breach-response');proof=last('breach-transaction-proof')
coop=last('cooperative-close');force=last('force-close');lock=last('force-close-timelock')
reboots=[o for o in d['outcomes'] if o['name']=='reboot-persistence' and o.get('configuration')=='persistent-mesh-mac']
assert len(reboots)==3
tcp=[p['receiver_mbps']['mean'] for p in d['iperf_summary']]
received=sum(p['received'] for p in d['pings']);sent=sum(p['transmitted'] for p in d['pings'])

title='LNMesh: headline findings'
subtitle='Experiment: 7-8 September 2026 UTC | Three Raspberry Pi 5s | Bitcoin regtest'
lead='Two Pis without an internet route completed funding, channel opening, payments, closing, and breach response through a mesh gateway using stock Bitcoin Core and LND.'
setup='A = pi1gateway; B = pi2; C = pi3. B and C used Neutrino with A as their sole Bitcoin peer over onboard Wi-Fi and batman-adv. The devices were a few inches apart on one table.'
headlines=[
    ['Funding and opening','B and C each received 2,000,000 sat on-chain; B opened a 1,000,000-sat channel to C. B also received 400,000 sat of channel balance while its on-chain wallet was zero.'],
    ['Payments and chain outage','150/150 measured payments settled. This included 30/30 while Bitcoin Core was stopped and the leaves\' chain height stayed unchanged.'],
    ['Both closure types',f'B recovered {commas(coop["wallet_delta_sat"])} sat cooperatively and {commas(force["wallet_delta_sat"])} sat after a force close and its {commas(lock["remaining_blocks"])}-block delay.'],
    ['Breach response',f'A disposable node published revoked state at height {breach["revoked_height"]}. B\'s justice transaction confirmed at {breach["justice_height"]}, recovering {commas(proof["justice_output_sat"])} sat from both principal outputs.'],
    ['Connectivity and recovery',f'{received}/{sent} ICMP packets arrived. Mean TCP throughput by tested direction ranged from {min(tcp):.2f} to {max(tcp):.2f} Mbit/s (three trials each). All three Pis recovered after individual reboots following a persistent-MAC fix.'],
]
timing=[]
for p in planned:
    direction=p['payer'].upper()+' to '+p['payee'].upper()
    condition='Core stopped' if p['condition']=='chain-stopped' else 'Core running'
    timing.append([direction,commas(p['amount_sat']),condition,'30/30',f'{p["cli_ms"]["median"]:.0f}'])
timing_note='Timing is median local CLI payment duration, including process/RPC work and settlement; it excludes SSH setup and invoice creation. All measured routes used one hop and zero routing fees. The 291 vs 289 ms matched medians do not establish an outage performance benefit.'
limits='Scope: one close-range, sequential regtest deployment. Leaf isolation was software-enforced; Ethernet cables remained attached. No forced multi-hop path, field range, hostile gateway, or mainnet behavior was tested. The one-block justice gap reflects manually mined regtest blocks.'
evidence='Evidence: four early preflight/install stdout records were damaged by filename collisions; preflight was repeated. Payment and channel results were unaffected. The full report documents these defects, recovery fixes, and raw evidence.'
end='At the final checkpoint (8 September, 00:12:28 UTC), the original three-node triangle had three active channels; a further post-reboot payment settled. All amounts are simulated regtest satoshis.'

navy=colors.HexColor('#233447');ink=colors.HexColor('#15202b')
styles={
    'title':ParagraphStyle('Title',fontName='Helvetica-Bold',fontSize=23,leading=27,textColor=navy,spaceAfter=5),
    'sub':ParagraphStyle('Sub',fontName='Helvetica',fontSize=8.5,leading=11,textColor=colors.HexColor('#566474'),spaceAfter=10),
    'lead':ParagraphStyle('Lead',fontName='Helvetica-Bold',fontSize=11,leading=14,textColor=ink,spaceAfter=7),
    'body':ParagraphStyle('Body',fontName='Helvetica',fontSize=9,leading=12,textColor=ink,spaceAfter=7),
    'small':ParagraphStyle('Small',fontName='Helvetica',fontSize=8,leading=10.3,textColor=ink,spaceAfter=6),
    'cell':ParagraphStyle('Cell',fontName='Helvetica',fontSize=8.5,leading=10.8,textColor=ink),
    'head':ParagraphStyle('Head',fontName='Helvetica-Bold',fontSize=8.3,leading=10.5,textColor=colors.white),
}
def para(s,style='body'):return Paragraph(html.escape(str(s)),styles[style])
def table(head,rows,widths):
    t=Table([[para(v,'head') for v in head]]+[[para(v,'cell') for v in r] for r in rows],colWidths=[w*inch for w in widths],hAlign='LEFT')
    t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),navy),('VALIGN',(0,0),(-1,-1),'TOP'),('ROWBACKGROUNDS',(0,1),(-1,-1),[colors.white,colors.HexColor('#F0F4F7')]),('LINEBELOW',(0,0),(-1,-1),.35,colors.HexColor('#d6dce2')),('LEFTPADDING',(0,0),(-1,-1),7),('RIGHTPADDING',(0,0),(-1,-1),7),('TOPPADDING',(0,0),(-1,-1),5),('BOTTOMPADDING',(0,0),(-1,-1),5)]))
    return t
story=[para(title,'title'),para(subtitle,'sub'),para(lead,'lead'),para(setup),table(['Finding','Observed result'],headlines,[1.35,5.75]),Spacer(1,9),table(['Payment direction','Amount (sat)','Condition','Settled','Median (ms)'],timing,[1.35,1.2,2.15,1,1.4]),Spacer(1,7),para(timing_note,'small'),para(limits,'small'),para(evidence,'small'),para(end,'small')]
def footer(canvas,doc):
    canvas.saveState();canvas.setFont('Helvetica',7.5);canvas.setFillColor(colors.HexColor('#566474'))
    canvas.drawString(.7*inch,.32*inch,'Source: LNMesh-research-writeup.pdf (17 pages), analysis.json, and the recorded outcomes.')
    canvas.drawRightString(7.8*inch,.32*inch,str(doc.page));canvas.restoreState()
pdf=OUT/'LNMesh-headline-findings.pdf'
doc=SimpleDocTemplate(str(pdf),pagesize=(8.5*inch,11*inch),leftMargin=.7*inch,rightMargin=.7*inch,topMargin=.48*inch,bottomMargin=.5*inch,title=title,author='LNMesh experiment record',subject='Condensed findings from the September 2026 three-Pi regtest deployment')
doc.build(story,onFirstPage=footer,onLaterPages=footer)
def mdtable(head,rows):return '\n'.join(['| '+' | '.join(head)+' |','| '+' | '.join(['---']*len(head))+' |']+['| '+' | '.join(row)+' |' for row in rows])
md='\n\n'.join(['# '+title,subtitle,'**'+lead+'**',setup,mdtable(['Finding','Observed result'],headlines),mdtable(['Payment direction','Amount (sat)','Condition','Settled','Median (ms)'],timing),timing_note,limits,evidence,end,'Source: [full report](LNMesh-research-writeup.pdf), [analysis](analysis.json), and [recorded outcomes](../evidence/outcomes.jsonl).'])+'\n'
mdpath=OUT/'LNMesh-headline-findings.md';mdpath.write_text(md,encoding='utf-8',newline='\n')
provenance=dict(generated_utc=dt.datetime.now(dt.timezone.utc).isoformat(),source_file=source.name,source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),artifacts={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [pdf,mdpath]})
(OUT/'LNMesh-headline-findings.provenance.json').write_text(json.dumps(provenance,indent=2),encoding='utf-8',newline='\n')
print(pdf)
