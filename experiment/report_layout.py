"""One content model for editable Markdown, HTML, and a typeset PDF."""
from pathlib import Path
import html,re,sys
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'.python-deps'))
import markdown
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet,ParagraphStyle
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate,Paragraph,Spacer,Table,TableStyle,Image,PageBreak,KeepTogether

class Article:
    def __init__(self):self.blocks=[]
    def title(self,t):self.blocks.append(('title',t))
    def h(self,t):self.blocks.append(('h',t))
    def p(self,t):self.blocks.append(('p',t))
    def table(self,heads,rows,widths=None):self.blocks.append(('table',heads,rows,widths))
    def figure(self,path,caption):self.blocks.append(('figure',str(path),caption))
    def page(self):self.blocks.append(('page',))

def inline(s):
    s=html.escape(str(s))
    s=re.sub(r'\[([^\]]+)\]\(([^)]+)\)',lambda m:f'<link href="{m[2]}">{m[1]}</link>',s)
    s=re.sub(r'\*\*([^*]+)\*\*',r'<b>\1</b>',s)
    s=re.sub(r'`([^`]+)`',r'<font face="Courier" size="8">\1</font>',s)
    return s

def render(article,out):
    out=Path(out);out.mkdir(exist_ok=True,parents=True)
    styles=getSampleStyleSheet()
    body=ParagraphStyle('ResearchBody',fontName='Helvetica',fontSize=10,leading=14,spaceAfter=8,textColor=colors.HexColor('#111111'))
    title=ParagraphStyle('ResearchTitle',parent=body,fontName='Helvetica-Bold',fontSize=22,leading=26,spaceAfter=16)
    heading=ParagraphStyle('ResearchHeading',parent=body,fontName='Helvetica-Bold',fontSize=15,leading=19,spaceBefore=3,spaceAfter=11,keepWithNext=True)
    small=ParagraphStyle('ResearchSmall',parent=body,fontSize=8.5,leading=11,spaceAfter=7)
    cell=ParagraphStyle('ResearchCell',parent=small,fontSize=8.3,leading=10.7,spaceAfter=0)
    headcell=ParagraphStyle('ResearchHeaderCell',parent=cell,fontName='Helvetica-Bold',textColor=colors.white)
    story=[];md=[]
    width=7.0*inch
    for b in article.blocks:
        kind=b[0]
        if kind=='page':story.append(PageBreak());continue
        if kind in ['title','h','p']:
            style={'title':title,'h':heading,'p':body}[kind]
            story.append(Paragraph(inline(b[1]),style));md.append(('# ' if kind=='title' else '## ' if kind=='h' else '')+b[1])
        elif kind=='table':
            _,heads,rows,widths=b
            tabledata=[[Paragraph(inline(v),headcell) for v in heads]]+[[Paragraph(inline(v),cell) for v in r] for r in rows]
            widths=[width*x/sum(widths) for x in widths] if widths else [width/len(heads)]*len(heads)
            tab=Table(tabledata,colWidths=widths,repeatRows=1,hAlign='LEFT')
            tab.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),colors.HexColor('#233447')),('VALIGN',(0,0),(-1,-1),'TOP'),('GRID',(0,0),(-1,-1),0.4,colors.HexColor('#D9D9D9')),('LEFTPADDING',(0,0),(-1,-1),6),('RIGHTPADDING',(0,0),(-1,-1),6),('TOPPADDING',(0,0),(-1,-1),6),('BOTTOMPADDING',(0,0),(-1,-1),6),('ROWBACKGROUNDS',(0,1),(-1,-1),[colors.white,colors.HexColor('#F1F4F7')])]))
            story += [tab,Spacer(1,10)]
            md += ['| '+' | '.join(map(str,heads))+' |','| '+' | '.join(['---']*len(heads))+' |']+['| '+' | '.join(str(v).replace('|','/') for v in r)+' |' for r in rows]
        elif kind=='figure':
            im=Image(b[1]);im.drawHeight=width*im.imageHeight/im.imageWidth;im.drawWidth=width
            story.append(KeepTogether([im,Spacer(1,5),Paragraph(inline(b[2]),small),Spacer(1,7)]))
            md.append(f'![{b[2]}]({Path(b[1]).relative_to(out).as_posix()})')
        md.append('')
    text='\n'.join(md)
    (out/'LNMesh-research-writeup.md').write_text(text,encoding='utf-8',newline='\n')
    web=markdown.markdown(text,extensions=['tables','fenced_code'])
    (out/'LNMesh-research-writeup.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>LNMesh research writeup</title><style>body{max-width:1000px;margin:50px auto;padding:0 25px;font:17px/1.65 system-ui;color:#15202b}h1,h2{line-height:1.2;color:#111}h2{margin-top:2.2em}table{border-collapse:collapse;width:100%;font-size:14px}th,td{border:1px solid #d9d9d9;padding:9px;text-align:left;overflow-wrap:anywhere}th{background:#233447;color:white}tr:nth-child(even){background:#f1f4f7}img{max-width:100%}code{font-size:.85em;overflow-wrap:anywhere}a{color:#175b9b}@media print{body{margin:0;font-size:11pt}}</style><main>'+web+'</main></html>',encoding='utf-8')
    def footer(canvas,doc):
        canvas.saveState();canvas.setFont('Helvetica',8);canvas.setFillColor(colors.HexColor('#555555'))
        canvas.drawString(.75*inch,.42*inch,'LNMesh regtest experiment | 7-8 September 2026 UTC')
        canvas.drawRightString(7.75*inch,.42*inch,str(doc.page));canvas.restoreState()
    doc=SimpleDocTemplate(str(out/'LNMesh-research-writeup.pdf'),pagesize=(8.5*inch,11*inch),leftMargin=.75*inch,rightMargin=.75*inch,topMargin=.65*inch,bottomMargin=.65*inch,title='LNMesh regtest replication on three Raspberry Pi 5 nodes',author='LNMesh experiment record',subject='Recorded deployment, offline channel lifecycle experiments, measurements, and limitations')
    doc.build(story,onFirstPage=footer,onLaterPages=footer)
