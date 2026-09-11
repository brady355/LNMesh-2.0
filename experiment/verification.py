"""Final persistence checks, host metadata, and evidence packaging inputs."""
import argparse,datetime as dt,json,time
from experiment import Experiment,outcome
from runner import BASE,EVIDENCE,Runner,utc

def reboot(hosts='bca'):
    e=Experiment();e.load_keys();original=dict(e.keys)
    for h in hosts:
        old=e.r.run(h,'cat /proc/sys/kernel/random/boot_id',label='boot-id-before')['stdout'].strip()
        mac=e.r.run(h,'cat /sys/class/net/bat0/address',label='mesh-mac-before-reboot')['stdout'].strip()
        start=utc();t=time.monotonic()
        e.r.run(h,'systemd-run --unit=lnmesh-reboot --on-active=3s /usr/bin/systemctl reboot',label='schedule-reboot')
        time.sleep(12)
        deadline=time.monotonic()+180
        while True:
            probe=e.r.run(h,'set -e\ncat /proc/sys/kernel/random/boot_id\nsystemctl is-active lnmesh-mesh chrony lnd\nlncli-mesh getinfo >/dev/null',label='reboot-recovery-probe',timeout=15,check=False)
            lines=probe['stdout'].splitlines()
            if probe['returncode']==0 and lines and lines[0]!=old:break
            if time.monotonic()>deadline:raise TimeoutError(f'{h} reboot recovery')
            time.sleep(5)
        # Gateway LAN and local services can recover before mesh forwarding.
        for target in 'abc':
            deadline=time.monotonic()+180
            while True:
                ready=e.r.run(target,'lncli-mesh getinfo >/dev/null',label='post-reboot-path-ready',timeout=15,check=False)
                if ready['returncode']==0:break
                if time.monotonic()>deadline:raise TimeoutError(f'{target} management path after {h} reboot')
                time.sleep(5)
        e.synced();e.active('a','b');e.active('a','c');e.active('b','c')
        for leaf in 'bc':
            e.r.run(leaf,'set -e\ntest -z "$(ip -4 route show default)"\ntest -z "$(ip -6 route show default)"\ntest -z "$(ip -o addr show dev eth0)"',label='isolation-after-reboot')
        aftermac=e.r.run(h,'cat /sys/class/net/bat0/address',label='mesh-mac-after-reboot')['stdout'].strip()
        assert aftermac==mac
        outcome('reboot-persistence',host=h,configuration='persistent-mesh-mac',started_controller_utc=start,observed_recovered_controller_utc=utc(),observed_recovery_seconds=time.monotonic()-t,boot_id_before=old,boot_id_after=lines[0],mesh_mac=mac)
    e.load_keys();assert e.keys==original
    e.pay('b','c',1000,'post-reboot-functional-check')
    e.snapshot('final-active-triangle')

def metadata():
    r=Runner('mesh',verbose='summary')
    for h in 'abc':
        r.run(h,(BASE/'scripts/final-status.sh').read_text(),label='final-host-metadata',timeout=120)
        for i in range(3):
            value=r.json(h,"python3 -c 'import time,socket,json; print(json.dumps(dict(hostname=socket.gethostname(),time_ns=time.time_ns())))'",root=False,label='clock-bracket')
    # Read the final records to preserve controller brackets around remote clock samples.
    events=[json.loads(x) for x in (EVIDENCE/'events.jsonl').read_text().splitlines()]
    clocks=[]
    for ev in events:
        if ev.get('state')!='finished' or ev['label']!='clock-bracket':continue
        sample=json.loads((EVIDENCE/ev['stdout_file']).read_text())
        a=dt.datetime.fromisoformat(ev['started_utc']).timestamp();b=dt.datetime.fromisoformat(ev['ended_utc']).timestamp();s=sample['time_ns']/1e9
        clocks.append(dict(host=ev['host'],controller_start_utc=ev['started_utc'],controller_end_utc=ev['ended_utc'],remote_epoch_ns=sample['time_ns'],remote_minus_controller_lower_seconds=s-b,remote_minus_controller_upper_seconds=s-a))
    (EVIDENCE/'clock-brackets.json').write_text(json.dumps(clocks,indent=2),encoding='utf-8')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('phase',choices=['reboot','metadata']);p.add_argument('--hosts',default='bca');ns=p.parse_args()
    if ns.phase=='reboot':
        assert ns.hosts and set(ns.hosts)<=set('abc');reboot(ns.hosts)
    else:metadata()
