"""Small SSH experiment runner. Passwords travel on stdin and are never logged."""
from __future__ import annotations
import argparse, concurrent.futures, datetime as dt, getpass, hashlib, json, os
from pathlib import Path
import re, shlex, subprocess, sys, threading, time, uuid
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

BASE = Path(__file__).resolve().parent
EVIDENCE = BASE / "evidence"
HOSTS = {"a": "pi1gateway", "b": "pi2", "c": "pi3"}
MESH = {"a": "10.10.0.1", "b": "10.10.0.2", "c": "10.10.0.3"}
LOCK = threading.Lock()

def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds")

def digest(data):
    return hashlib.sha256(data).hexdigest()

def append_event(event):
    EVIDENCE.mkdir(exist_ok=True)
    with LOCK, (EVIDENCE / "events.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
        f.flush()

def scrub(text):
    text = re.sub(r'("(?:payment_preimage|r_preimage)"\s*:\s*")[^"]*"', r'\1[REDACTED]"', text)
    return re.sub(r'(?im)^([^\n]*(?:rpcpass|rpcauth|password|mnemonic|seed phrase)\s*[=:]).*$', r'\1[REDACTED]', text)

class Runner:
    def __init__(self, route="lan", verbose=True):
        self.route, self.verbose = route, verbose
        self.password = os.environ.get("LN_MESH_SUDO_PASSWORD")

    def run(self, host, script, *, label="command", root=True, timeout=120, check=True, route=None):
        route = route or self.route
        script = "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n" + script.replace("\r\n", "\n")
        if root and self.password is None:
            self.password = getpass.getpass("Pi sudo password: ")
        args = ["ssh", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=yes"]
        if route == "mesh" and host != "a":
            args += ["-o", f"HostKeyAlias={HOSTS[host]}", "-J", "brady@pi1gateway"]
            target = MESH[host]
        else:
            target = HOSTS[host]
        remote = ("sudo -k -S -p '' -- " if root else "") + "bash -c " + shlex.quote(script)
        args += [f"brady@{target}", remote]
        event_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S-%fZ") + f"-{host}-{uuid.uuid4().hex[:6]}"
        stem = EVIDENCE / event_id
        EVIDENCE.mkdir(exist_ok=True)
        stem.with_suffix(".sh").write_text(scrub(script), encoding="utf-8", newline="\n")
        event = dict(id=event_id, label=label, host=host, hostname=HOSTS[host], transport=route, target=target, root=root, started_utc=utc(), script_sha256=digest(scrub(script).encode()), script_file=stem.with_suffix(".sh").name)
        append_event({**event, "state": "started"})
        start = time.perf_counter()
        try:
            proc = subprocess.run(args, input=(self.password + "\n").encode() if root else b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
            code, out, err = proc.returncode, proc.stdout.decode("utf-8", "replace"), proc.stderr.decode("utf-8", "replace")
        except subprocess.TimeoutExpired as exc:
            code, out, err = 124, (exc.stdout or b"").decode("utf-8", "replace"), (exc.stderr or b"").decode("utf-8", "replace") + "\nLOCAL SSH TIMEOUT; inspect remote state before retrying\n"
        out, err = scrub(out), scrub(err)
        event.update(state="finished", ended_utc=utc(), elapsed_seconds=time.perf_counter()-start, returncode=code)
        stem.with_suffix(".stdout.txt").write_text(out, encoding="utf-8", newline="\n")
        stem.with_suffix(".stderr.txt").write_text(err, encoding="utf-8", newline="\n")
        event.update(stdout_file=stem.with_suffix(".stdout.txt").name, stderr_file=stem.with_suffix(".stderr.txt").name, stdout_sha256=digest(out.encode()), stderr_sha256=digest(err.encode()))
        append_event(event)
        if self.verbose:
            with LOCK:
                print(f"[{event['ended_utc']}] {host} {label}: rc={code} {event['elapsed_seconds']:.3f}s", flush=True)
                if self.verbose is True or code:
                    print(out[-18000:], end="" if out.endswith("\n") else "\n", flush=True)
                    if err: print(err[-5000:], flush=True)
        if check and code:
            raise RuntimeError(f"{host} {label} failed ({code}); see {stem}")
        return {"event": event, "stdout": out, "stderr": err, "returncode": code}

    def json(self, host, command, **kwargs):
        return json.loads(self.run(host, "set -euo pipefail\n" + command, **kwargs)["stdout"])

def main():
    p = argparse.ArgumentParser()
    p.add_argument("script", type=Path)
    p.add_argument("--hosts", default="abc")
    p.add_argument("--label", default="script")
    p.add_argument("--route", choices=["lan", "mesh"], default="lan")
    p.add_argument("--timeout", type=int, default=180)
    p.add_argument("--user", action="store_true")
    ns = p.parse_args()
    script = ns.script.read_text(encoding="utf-8")
    r = Runner(ns.route)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        jobs = [pool.submit(r.run, h, script, label=ns.label, root=not ns.user, timeout=ns.timeout) for h in ns.hosts]
        for job in jobs: job.result()

if __name__ == "__main__": main()
