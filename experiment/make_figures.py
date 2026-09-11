"""Publication-oriented figures from measured values, with SVG and PNG exports."""
import csv,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'.python-deps'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
import numpy as np

def figures():
    out=ROOT/'report';figdir=out/'figures';figdir.mkdir(exist_ok=True)
    data=json.loads((out/'analysis.json').read_text())
    rows=list(csv.DictReader((out/'payments.csv').open()))
    plt.rcParams.update({'font.size':10,'axes.spines.top':False,'axes.spines.right':False,'svg.fonttype':'none','savefig.dpi':220,'font.family':'DejaVu Sans'})
    def save(fig,name):
        fig.savefig(figdir/(name+'.png'),bbox_inches='tight',facecolor='white')
        fig.savefig(figdir/(name+'.svg'),bbox_inches='tight',facecolor='white');plt.close(fig)
    fig,ax=plt.subplots(figsize=(8.3,3.4))
    palette=['#23628c','#c06c2b','#427b57']
    for (src,dst),col in zip([('b','c'),('b','a'),('a','b')],palette):
        vals=sorted(float(r['local_cli_elapsed_ms']) for r in rows if r['condition']=='chain-running' and r['payer']==src and r['payee']==dst)
        ax.step(vals,np.arange(1,len(vals)+1)/len(vals),where='post',label=f'{src.upper()} to {dst.upper()} (n={len(vals)})',color=col,lw=1.8)
    ax.set(xlabel='Local CLI payment duration (ms)',ylabel='Empirical cumulative fraction',ylim=(0,1.03));ax.grid(alpha=.18);ax.legend(loc='lower right')
    save(fig,'payment-ecdf')
    fig,ax=plt.subplots(figsize=(8.3,3.4))
    for cond,label,col in [('baseline-chain-running','Bitcoin Core running','#23628c'),('chain-stopped','Bitcoin Core stopped','#c06c2b')]:
        vals=sorted(float(r['local_cli_elapsed_ms']) for r in rows if r['condition']==cond)
        ax.step(vals,np.arange(1,len(vals)+1)/len(vals),where='post',label=f'{label} (n={len(vals)})',color=col,lw=1.8)
    ax.set(xlabel='Local CLI payment duration (ms)',ylabel='Empirical cumulative fraction',ylim=(0,1.03));ax.grid(alpha=.18);ax.legend(loc='lower right')
    save(fig,'baseline-ecdf')
    fig,axes=plt.subplots(1,2,figsize=(8.4,3.5))
    ping=data['pings'];labels=[f"{r['source'].upper()}-{r['destination'].upper()}" for r in ping]
    axes[0].boxplot([r['values_ms'] for r in ping],tick_labels=labels,showfliers=True,medianprops={'color':'#c06c2b'})
    axes[0].set(ylabel='Mesh ICMP round-trip time (ms)',xlabel='Direction (100 packets each)');axes[0].grid(axis='y',alpha=.18)
    for i,(src,dst) in enumerate([('b','a'),('c','a'),('b','c')]):
        vals=[r['receiver_mbps'] for r in data['iperf'] if r['source']==src and r['destination']==dst]
        axes[1].scatter([i-.12,i,i+.12],vals,color='#23628c',s=35)
        axes[1].plot([i-.2,i+.2],[np.mean(vals)]*2,color='#c06c2b',lw=2)
    axes[1].set(xticks=[0,1,2],xticklabels=['B-A','C-A','B-C'],ylabel='TCP receiver throughput (Mbit/s)',xlabel='Direction (3 trials of 10 seconds)',ylim=(0,55));axes[1].grid(axis='y',alpha=.18)
    fig.tight_layout();save(fig,'mesh-performance')
    fig,ax=plt.subplots(figsize=(8.3,3.7));ax.set(xlim=(0,10),ylim=(0,4.6));ax.axis('off')
    boxes=[(4,3.1,2,1.1,'A  pi1gateway\nBitcoin Core + LND\n10.10.0.1'),(.7,.5,2.9,1.1,'B  pi2\nLND + Neutrino\n10.10.0.2'),(6.4,.5,2.9,1.1,'C  pi3\nLND + Neutrino\n10.10.0.3')]
    for x,y,w,h,text in boxes:
        ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle='round,pad=0.06',fc='#f1f4f7',ec='#233447',lw=1.2));ax.text(x+w/2,y+h/2,text,ha='center',va='center',fontsize=10)
    ax.plot([4.25,2.8],[3.1,1.6],color='#23628c',lw=1.8);ax.plot([5.75,7.2],[3.1,1.6],color='#23628c',lw=1.8);ax.plot([3.6,6.4],[1.05,1.05],color='#23628c',lw=1.8)
    ax.text(5,2.25,'Wi-Fi IBSS\nbatman-adv\n2412 MHz / 20 MHz',ha='center',va='center',fontsize=9)
    ax.text(5,.23,'Leaves have no Ethernet IP or default route; gateway IP forwarding is disabled.',ha='center',fontsize=9)
    ax.annotate('LAN and internet',xy=(5,4.2),xytext=(5,4.48),ha='center',arrowprops={'arrowstyle':'-'},fontsize=9)
    save(fig,'topology')

if __name__=='__main__':figures()
