#!/usr/bin/env python3
"""Time one local CLI operation; do not include SSH or sudo authentication time."""
import datetime as dt,json,socket,subprocess,sys,time

def clean(x):
    if isinstance(x,dict):
        return {k:('[REDACTED]' if k in {'payment_preimage','r_preimage','seed','mnemonic','rpcpass','password'} else clean(v)) for k,v in x.items()}
    if isinstance(x,list): return [clean(v) for v in x]
    return x

start=dt.datetime.now(dt.timezone.utc).isoformat(timespec='microseconds')
t=time.perf_counter_ns()
p=subprocess.run(sys.argv[1:],capture_output=True,text=True)
elapsed=time.perf_counter_ns()-t
end=dt.datetime.now(dt.timezone.utc).isoformat(timespec='microseconds')
remaining=p.stdout.strip(); objects=[]
try:
    while remaining:
        obj,n=json.JSONDecoder().raw_decode(remaining)
        objects.append(clean(obj)); remaining=remaining[n:].lstrip()
    result=objects[0] if len(objects)==1 else objects
except ValueError:
    result=p.stdout
print(json.dumps(dict(hostname=socket.gethostname(),started_utc=start,ended_utc=end,elapsed_ns=elapsed,returncode=p.returncode,result=result,stderr=p.stderr)))
sys.exit(p.returncode)
