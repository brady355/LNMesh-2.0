#!/usr/bin/env python3
"""hydrapay: minimum viable client for a two-party Hydra Head on the mesh testbed.

One process runs next to each hydra-node. hydra-node does the protocol work,
so it signs snapshots, closes the head, contests a stale close on its own and
fans out. It reaches the cardano-node of the gateway through a forwarded
socket. This program is the thin wallet around it. It deposits the funds of
the leaf into the head, builds and signs fee-free head transactions as
payments, drives the close and the fanout, and logs every head event with a
timestamp, so the scripts can measure the protocol.

Without -skey the program runs as an observer. The gateway runs one observer
next to each mirror hydra-node, and the mirror is the watchtower of this arm.
The mirror holds the Hydra key and the Cardano node key of its party, so it
contests a stale close by itself. The observer logs the events of the mirror
and can trigger the fanout. It runs without the funds key, so it can neither
pay nor deposit.

Subcommands: node, ctl. Nothing here is production code.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import websocket  # websocket-client
from pycardano import (Address, Network, PaymentSigningKey, PaymentVerificationKey, Transaction, TransactionBody,
                       TransactionId, TransactionInput, TransactionOutput, TransactionWitnessSet,
                       VerificationKeyWitness)

LOVELACE = 1_000_000


def ts():
    return datetime.now(timezone.utc).strftime("%H:%M:%S.%f")[:-3]


def log(*a):
    print(ts(), *a, flush=True)


def now_ms():
    return time.monotonic() * 1000.0


def ada(lovelace):
    s = f"{int(lovelace) / LOVELACE:.6f}".rstrip("0").rstrip(".")
    return s if s not in ("", "-0") else "0"


def to_lovelace(amount_ada):
    return int(round(float(amount_ada) * LOVELACE))


def hostport(s):
    h, p = s.rsplit(":", 1)
    return h, int(p)


def readline(sock, limit=1 << 16):
    buf = b""
    while b"\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
        if len(buf) > limit:
            raise ValueError("line too long")
    return buf.split(b"\n", 1)[0].decode()


def lovelace_of(txout):
    v = txout.get("value", {})
    return int(v.get("lovelace", 0))


def only_lovelace(txout):
    return set(txout.get("value", {}).keys()) <= {"lovelace"}


def sum_by_address(utxo):
    out = {}
    for txout in (utxo.values() if isinstance(utxo, dict) else utxo):
        out[txout["address"]] = out.get(txout["address"], 0) + lovelace_of(txout)
    return out


class Node:
    def __init__(self, args):
        self.args = args
        if args.skey:
            self.skey = PaymentSigningKey.load(args.skey)
            self.vkey = PaymentVerificationKey.from_signing_key(self.skey)
            self.addr = Address(self.vkey.hash(), network=Network.TESTNET)
        else:   # an observer next to a mirror node has no funds key, so it cannot pay or deposit
            self.skey = self.vkey = self.addr = None
        self.peer_addr = Address(PaymentVerificationKey.load(args.peer_vkey).hash(), network=Network.TESTNET) if args.peer_vkey else None
        self.http = f"http://{args.api}"
        self.wsurl = f"ws://{args.api}/?history=no"
        self.ws = None
        self.lock = threading.RLock()
        self.cond = threading.Condition(self.lock)
        self.events = []          # (wall time, monotonic ms, message)
        self.utxo = {}            # latest confirmed head UTxO
        self.snapshot = None      # latest confirmed snapshot number
        self.head_status = "unknown"
        self.synced = "unknown"
        self.node_version = "unknown"
        self.env = {}
        self.ready_to_fanout = False
        self.deposits = []        # deposit tx ids seen in CommitRecorded, newest last

    # ---------------- hydra-node API ----------------
    def ws_loop(self):
        while True:
            try:
                app = websocket.WebSocketApp(self.wsurl, on_open=self.on_open, on_message=self.on_message,
                                             on_error=self.on_error, on_close=self.on_close)
                app.run_forever(ping_interval=20, ping_timeout=10)
            except Exception as e:  # noqa: BLE001
                log(f"API loop error: {type(e).__name__}: {e}")
            with self.lock:
                self.ws = None
            time.sleep(2)

    def on_open(self, app):
        with self.lock:
            self.ws = app
        log(f"API connected {self.wsurl}")

    def on_error(self, app, err):
        if "Connection refused" not in str(err):
            log(f"API error: {err}")

    def on_close(self, app, code, reason):
        log(f"API closed ({code} {reason})")
        with self.lock:
            self.ws = None

    def on_message(self, app, raw):
        try:
            m = json.loads(raw)
        except ValueError:
            return
        tag = m.get("tag", "?")
        with self.cond:
            self.events.append((ts(), now_ms(), m))
            if len(self.events) > 5000:
                del self.events[:1000]
            self.handle(tag, m)
            self.cond.notify_all()

    def handle(self, tag, m):
        if tag == "Greetings":
            self.head_status = m.get("headStatus", "?")
            self.synced = m.get("chainSyncedStatus", "?")
            self.node_version = m.get("hydraNodeVersion", "?")
            self.env = m.get("env", {})
            if m.get("snapshotUtxo") is not None:
                self.utxo = m["snapshotUtxo"]
            log(f"GREETINGS head {self.head_status} synced {self.synced} node {self.node_version} "
                f"cp {self.env.get('contestationPeriod')}s peers {m.get('networkInfo', {}).get('peersInfo')}")
        elif tag == "SnapshotConfirmed":
            sn = m["snapshot"]
            self.snapshot = sn.get("number")
            if sn.get("utxo") is not None:
                self.utxo = sn["utxo"]
            log(f"SNAPSHOT {self.snapshot} confirmed, {len(sn.get('confirmed', []))} tx, {len(self.utxo)} utxo")
        elif tag == "TxValid":
            log(f"TX valid {m.get('transactionId', '')[:16]}")
        elif tag == "TxInvalid":
            log(f"TX invalid: {json.dumps(m.get('validationError'))[:300]}")
        elif tag == "HeadIsOpen":
            self.head_status = "Open"
            log(f"HEAD open {m.get('headId', '')[:16]} parties {len(m.get('parties', []))}")
        elif tag in ("CommitRecorded", "DepositActivated", "CommitFinalized", "CommitRecovered", "DepositExpired"):
            if tag == "CommitRecorded" and m.get("pendingDeposit"):
                self.deposits.append(m["pendingDeposit"])
            log(f"DEPOSIT {tag} {str(m.get('depositTxId') or m.get('pendingDeposit') or '')[:16]} "
                f"deadline {m.get('deadline', '')}")
        elif tag == "HeadIsClosed":
            self.head_status = "Closed"
            self.ready_to_fanout = False
            log(f"HEAD closed with snapshot {m.get('snapshotNumber')} contestation deadline {m.get('contestationDeadline')}")
        elif tag == "HeadIsContested":
            log(f"HEAD contested with snapshot {m.get('snapshotNumber')} new deadline {m.get('contestationDeadline')}")
        elif tag == "ReadyToFanout":
            self.ready_to_fanout = True
            log("HEAD ready to fanout")
        elif tag == "HeadIsFinalized":
            self.head_status = "Idle"
            by = sum_by_address(m.get("finalizedUTxO", {}))
            log(f"HEAD finalized: {' '.join(f'{a[-8:]}={ada(v)}' for a, v in by.items())}")
        elif tag == "PostTxOnChainFailed":
            err = dict(m.get("postTxError") or {})
            err.pop("failingTx", None)   # the transaction hex hides the reason
            log(f"POST TX FAILED {m.get('postChainTx', {}).get('tag')}: {json.dumps(err)[:600]}")
        elif tag == "CommandFailed":
            log(f"COMMAND FAILED {m.get('clientInput', {}).get('tag')} in state {m.get('state', {}).get('tag')}")
        elif tag == "RejectedInputBecauseUnsynced":
            log(f"REJECTED {m.get('clientInput', {}).get('tag')}: node unsynced, drift {m.get('drift')} s")
        elif tag in ("NodeUnsynced", "NodeSynced"):
            self.synced = "InSync" if tag == "NodeSynced" else "CatchingUp"
            log(f"{tag.upper()} drift {m.get('drift')} s chain slot {m.get('chainSlot')}")
        elif tag in ("PeerConnected", "PeerDisconnected", "NetworkConnected", "NetworkDisconnected"):
            log(f"NETWORK {tag} {m.get('peer', '')}")
        else:
            log(f"EVENT {tag}")

    def send(self, msg):
        with self.lock:
            app = self.ws
        if app is None:
            raise RuntimeError("hydra-node API not connected")
        app.send(json.dumps(msg))

    def mark(self):
        with self.lock:
            return len(self.events)

    def wait_pred(self, pred, since, timeout):
        """Wait for the first event after index `since` that satisfies `pred`.
        Returns (event, seconds since call) or (None, timeout)."""
        t0 = time.monotonic()
        deadline = t0 + timeout
        with self.cond:
            while True:
                for i in range(since, len(self.events)):
                    if pred(self.events[i][2]):
                        return self.events[i], time.monotonic() - t0
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None, timeout
                self.cond.wait(min(remaining, 5.0))

    def wait_for(self, tags, since, timeout):
        return self.wait_pred(lambda m: m.get("tag") in tags, since, timeout)

    def request(self, method, path, body=None, timeout=60):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.http + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"} if data else {})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read().decode()
                status = r.status
        except urllib.error.HTTPError as e:
            raw = e.read().decode()
            status = e.code
        try:
            return status, json.loads(raw)
        except ValueError:
            return status, raw

    # ---------------- commands ----------------
    def cmd_info(self):
        st, head = self.request("GET", "/head")
        tag = head.get("tag") if isinstance(head, dict) else str(head)[:60]
        mine = sum_by_address(self.utxo).get(str(self.addr), 0)
        return (f"OK address {self.addr} peer {self.peer_addr} api {self.http} head {tag} synced {self.synced} "
                f"node {self.node_version} cp {self.env.get('contestationPeriod')}s snapshot {self.snapshot} "
                f"utxos {len(self.utxo)} mine {ada(mine)} ADA")

    def cmd_init(self):
        since = self.mark()
        t0 = now_ms()
        self.send({"tag": "Init"})
        ev, _ = self.wait_for(("HeadIsOpen", "CommandFailed", "PostTxOnChainFailed", "RejectedInputBecauseUnsynced"),
                              since, 300)
        if ev is None:
            return "ERR init: no HeadIsOpen within 300 s"
        if ev[2]["tag"] != "HeadIsOpen":
            return f"ERR init: {ev[2]['tag']}"
        return f"OK head open {ev[2].get('headId', '')[:16]} in {now_ms() - t0:.0f} ms"

    def sign_with_cli(self, draft):
        wd = self.args.workdir
        os.makedirs(wd, exist_ok=True)
        dpath, spath = os.path.join(wd, "deposit-draft.json"), os.path.join(wd, "deposit-signed.json")
        with open(dpath, "w") as f:
            json.dump(draft, f)
        subprocess.run([self.args.cardano_cli, "conway", "transaction", "sign", "--tx-file", dpath,
                        "--signing-key-file", self.args.skey, "--out-file", spath], check=True, capture_output=True)
        with open(spath) as f:
            return json.load(f)

    def cmd_deposit(self):
        if self.skey is None:
            return "ERR observer: no funds key"
        if not self.args.cardano_cli or not self.args.socket:
            return "ERR deposit needs -cardano-cli and -socket"
        utxo = self.cli_utxo(self.addr)   # the live UTxO set of my funds address on layer 1
        if not utxo:
            return "ERR nothing to deposit: no UTxO at my funds address"
        total = sum(lovelace_of(o) for o in utxo.values())
        since = self.mark()
        t0 = now_ms()
        st, draft = self.request("POST", "/commit", {"utxoToCommit": utxo})
        if st != 200:
            return f"ERR commit draft: HTTP {st} {str(draft)[:300]}"
        t_draft = now_ms() - t0
        signed = self.sign_with_cli(draft)
        st, res = self.request("POST", "/cardano-transaction", signed)
        if st != 200:
            return f"ERR deposit submit: HTTP {st} {str(res)[:300]}"
        t_submit = now_ms() - t0
        stages = []
        # A failed IncrementTx is not fatal here, because with mirrors in the head
        # several nodes post the increment and every loser of that race logs one.
        for tag in ("CommitRecorded", "DepositActivated", "CommitFinalized"):
            ev, _ = self.wait_for((tag, "DepositExpired"), since, 600)
            if ev is None or ev[2]["tag"] != tag:
                got = None if ev is None else ev[2]["tag"]
                if got == "DepositExpired":   # the client brings the funds back to layer 1 at once
                    return f"ERR deposit expired after {now_ms() - t0:.0f} ms, {self.cmd_recover(str(ev[2].get('depositTxId') or ''))}"
                return f"ERR deposit: waited for {tag}, got {got} after {now_ms() - t0:.0f} ms"
            since = self.events.index(ev) + 1
            stages.append(f"{tag} {now_ms() - t0:.0f} ms")
        st, u = self.request("GET", "/snapshot/utxo")   # increments confirm without a SnapshotConfirmed event
        if st == 200 and isinstance(u, dict):
            with self.lock:
                self.utxo = u
        mine = sum_by_address(self.utxo).get(str(self.addr), 0)
        return (f"OK deposited {ada(total)} ADA: draft {t_draft:.0f} ms, submitted {t_submit:.0f} ms, "
                f"{', '.join(stages)}, total {now_ms() - t0:.0f} ms, mine in head {ada(mine)} ADA")

    def pick_input(self, need):
        best = None
        for txin, txout in self.utxo.items():
            if txout["address"] != str(self.addr) or not only_lovelace(txout):
                continue
            v = lovelace_of(txout)
            if v == need or v >= need + self.args.min_utxo:
                if best is None or v > lovelace_of(self.utxo[best]):
                    best = txin
        return best

    def cmd_pay(self, amount_ada):
        if self.skey is None:
            return "ERR observer: no funds key"
        t0 = now_ms()
        amount = to_lovelace(amount_ada)
        if amount < self.args.min_utxo:
            return f"ERR amount below the min-UTxO floor of {ada(self.args.min_utxo)} ADA"
        with self.lock:
            txin = self.pick_input(amount)
            if txin is None:
                mine = sum_by_address(self.utxo).get(str(self.addr), 0)
                return f"ERR no single UTxO of mine covers {ada(amount)} ADA plus change (mine {ada(mine)} ADA in {len(self.utxo)} utxo)"
            value = lovelace_of(self.utxo[txin])
        txid, ix = txin.split("#")
        outputs = [TransactionOutput(self.peer_addr, amount)]
        if value > amount:
            outputs.append(TransactionOutput(self.addr, value - amount))
        body = TransactionBody(inputs=[TransactionInput(TransactionId(bytes.fromhex(txid)), int(ix))],
                               outputs=outputs, fee=0)
        t1 = now_ms()
        wit = VerificationKeyWitness(self.vkey, self.skey.sign(body.hash()))
        t_sign = now_ms() - t1
        tx = Transaction(body, TransactionWitnessSet(vkey_witnesses=[wit]))
        envelope = {"type": "Tx ConwayEra", "description": "", "cborHex": tx.to_cbor_hex()}
        new_id = body.hash().hex()
        since = self.mark()
        st, res = self.request("POST", "/transaction", envelope, timeout=self.args.tx_timeout)
        t_http = now_ms() - t0
        tag = res.get("tag") if isinstance(res, dict) else str(res)[:200]
        if st not in (200, 202):
            detail = res.get("validationError") or res.get("reason") if isinstance(res, dict) else res
            return f"ERR pay: HTTP {st} {tag} {str(detail)[:300]} ({t_http:.0f} ms)"

        def done(m):   # the snapshot that confirms my transaction, or its rejection
            if m.get("tag") == "SnapshotConfirmed":
                return any(t.get("txId") == new_id for t in m["snapshot"].get("confirmed", []))
            return m.get("tag") == "TxInvalid" and m.get("transaction", {}).get("txId") == new_id

        ev, _ = self.wait_pred(done, since, self.args.tx_timeout)
        ms = now_ms() - t0
        if ev is None:
            return f"ERR pay: no confirming snapshot within {self.args.tx_timeout:.0f} s (HTTP {st} {tag})"
        if ev[2]["tag"] == "TxInvalid":
            return f"ERR pay: invalid {json.dumps(ev[2].get('validationError'))[:300]} ({ms:.0f} ms)"
        with self.lock:
            mine = sum_by_address(self.utxo).get(str(self.addr), 0)
        return (f"OK paid {amount_ada} ADA mine {ada(mine)} ADA snapshot {ev[2]['snapshot'].get('number')} "
                f"in {ms:.0f} ms (sign {t_sign:.1f} ms, http {t_http:.0f} ms)")

    def cmd_bal(self):
        by = sum_by_address(self.utxo)
        mine, peer = by.get(str(self.addr), 0), by.get(str(self.peer_addr), 0)
        return (f"OK head {self.head_status} snapshot {self.snapshot} utxos {len(self.utxo)} "
                f"mine {ada(mine)} ADA peer {ada(peer)} ADA other {ada(sum(by.values()) - mine - peer)} ADA")

    def cmd_close(self, full):
        since = self.mark()
        t0 = now_ms()
        # hydra-node bounds the validity of the close transaction by the
        # contestation period after the last block it saw, so a long block gap
        # lets the transaction expire in the mempool without any error.
        # Therefore the client sends the close again when it observes no close
        # within 90 s, up to three times.
        ev = None
        for attempt in range(3):
            self.send({"tag": "Close"})
            ev, _ = self.wait_for(("HeadIsClosed", "CommandFailed", "PostTxOnChainFailed", "RejectedInputBecauseUnsynced"),
                                  since, 90)
            if ev is not None:
                break
            log(f"close attempt {attempt + 1} not observed within 90 s, sending again")
        if ev is None or ev[2]["tag"] != "HeadIsClosed":
            return f"ERR close: {None if ev is None else ev[2]['tag']} after {now_ms() - t0:.0f} ms"
        closed = (f"closed with snapshot {ev[2].get('snapshotNumber')} in {now_ms() - t0:.0f} ms, "
                  f"deadline {ev[2].get('contestationDeadline')}")
        if not full:
            return "OK " + closed
        return "OK " + closed + "; " + self.fanout(since, t0)

    def fanout(self, since, t0):
        st, head = self.request("GET", "/head")
        if isinstance(head, dict) and head.get("tag") == "Idle":
            return "ERR head is already Idle: the peer fanned out before this node could"
        # A node that restarted after the deadline has already sent ReadyToFanout,
        # and this client never saw it, so the head state decides instead.
        already = isinstance(head, dict) and head.get("tag") == "Closed" and head.get("contents", {}).get("readyToFanoutSent")
        if already:
            ev = None
        else:
            ev, _ = self.wait_for(("ReadyToFanout", "HeadIsFinalized"), since, self.args.fanout_timeout)
            if ev is None:
                return f"ERR no ReadyToFanout within {self.args.fanout_timeout} s"
        if ev is not None and ev[2]["tag"] == "HeadIsFinalized":
            by = sum_by_address(ev[2].get("finalizedUTxO", {}))
            return (f"finalized by the peer at {now_ms() - t0:.0f} ms: mine {ada(by.get(str(self.addr), 0))} ADA "
                    f"peer {ada(by.get(str(self.peer_addr), 0))} ADA")
        t_ready = now_ms() - t0
        since = self.mark()
        self.send({"tag": "Fanout"})
        ev, _ = self.wait_for(("HeadIsFinalized", "CommandFailed", "PostTxOnChainFailed"), since, 600)
        if ev is None or ev[2]["tag"] != "HeadIsFinalized":
            return f"ERR fanout: {None if ev is None else ev[2]['tag']} after {now_ms() - t0:.0f} ms"
        by = sum_by_address(ev[2].get("finalizedUTxO", {}))
        return (f"ready to fanout at {t_ready:.0f} ms, finalized at {now_ms() - t0:.0f} ms: "
                f"mine {ada(by.get(str(self.addr), 0))} ADA peer {ada(by.get(str(self.peer_addr), 0))} ADA")

    def cmd_fanout(self):
        t0 = now_ms()
        since = 0 if self.ready_to_fanout else self.mark()
        return "OK " + self.fanout(since, t0)

    def cmd_recover(self, txid=None):
        if not txid:
            st, pending = self.request("GET", "/commits")
            if st != 200 or not isinstance(pending, list):
                return f"ERR commits: HTTP {st} {str(pending)[:200]}"
            if not pending:
                return "OK nothing to recover"
            txid = pending[0]
        since = self.mark()
        t0 = now_ms()
        st, res = self.request("DELETE", f"/commits/{txid}")
        if st != 200:
            return f"ERR recover {txid[:16]}: HTTP {st} {str(res)[:300]}"
        ev, _ = self.wait_for(("CommitRecovered", "PostTxOnChainFailed"), since, 120)
        return f"OK recover {txid[:16]}: HTTP {st} {str(res)[:100]}, {None if ev is None else ev[2]['tag']} after {now_ms() - t0:.0f} ms"

    def cmd_head(self):
        st, head = self.request("GET", "/head")
        if st != 200 or not isinstance(head, dict):
            return f"ERR head: HTTP {st}"
        c = head.get("contents", {})
        if head.get("tag") == "Closed":
            snap = c.get("confirmedSnapshot", {})
            n = snap.get("snapshot", {}).get("number", 0) if snap.get("tag") == "ConfirmedSnapshot" else 0
            return f"OK Closed snapshot {n} deadline {c.get('contestationDeadline')} readyToFanoutSent {c.get('readyToFanoutSent')}"
        if head.get("tag") == "Open":
            return f"OK Open cp {c.get('parameters', {}).get('contestationPeriod')}s"
        return f"OK {head.get('tag')}"

    def cmd_snapshot(self):
        st, s = self.request("GET", "/snapshot")
        if st != 200 or not isinstance(s, dict):
            return f"ERR snapshot: HTTP {st}"
        if s.get("tag") == "InitialSnapshot":
            return "OK InitialSnapshot"
        sn = s.get("snapshot", {})
        return f"OK ConfirmedSnapshot number {sn.get('number')} version {sn.get('version')} utxos {len(sn.get('utxo', {}))}"

    def cli_utxo(self, addr):
        out = subprocess.run([self.args.cardano_cli, "conway", "query", "utxo", "--address", str(addr),
                              "--socket-path", self.args.socket, "--testnet-magic", str(self.args.magic),
                              "--out-file", "/dev/stdout"], check=True, capture_output=True, timeout=60).stdout
        return json.loads(out)

    # ---------------- control ----------------
    def dispatch(self, argv):
        if not argv:
            return "ERR empty command"
        cmd, a = argv[0], argv[1:]
        if cmd == "ping":
            return "OK pong"
        if cmd == "info":
            return self.cmd_info()
        if cmd == "init":
            return self.cmd_init()
        if cmd == "deposit":
            return self.cmd_deposit()
        if cmd == "pay":
            return self.cmd_pay(a[0])
        if cmd == "bal":
            return self.cmd_bal()
        if cmd == "close":
            return self.cmd_close(full=True)
        if cmd == "closeonly":
            return self.cmd_close(full=False)
        if cmd == "fanout":
            return self.cmd_fanout()
        if cmd == "recover":
            return self.cmd_recover(a[0] if a else None)
        if cmd == "head":
            return self.cmd_head()
        if cmd == "snapshot":
            return self.cmd_snapshot()
        return f"ERR unknown command {cmd}"

    def ctl_server(self, listen):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(listen)
        srv.listen(8)
        log(f"control port on {listen[0]}:{listen[1]}")
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=self.handle_ctl, args=(conn,), daemon=True).start()

    def handle_ctl(self, conn):
        with conn:
            try:
                conn.settimeout(3600)
                argv = readline(conn).split()
                log("ctl", " ".join(argv))
                reply = self.dispatch(argv)
            except Exception as e:  # noqa: BLE001
                reply = f"ERR {type(e).__name__}: {e}"
            log("ctl reply:", reply.replace("\n", " | ")[:400 if reply.startswith("OK") else 4000])
            try:
                conn.sendall((reply + "\n").encode())
            except OSError:
                pass

    def run(self):
        log(f"hydrapay {'observer' if self.skey is None else 'node'} address {self.addr} peer {self.peer_addr} api {self.http}")
        threading.Thread(target=self.ws_loop, daemon=True).start()
        threading.Thread(target=self.ctl_server, args=(hostport(self.args.ctl),), daemon=True).start()
        log("node ready")
        while True:
            time.sleep(3600)


def cmd_ctl(a):
    with socket.create_connection(hostport(a.addr), timeout=a.timeout) as s:
        s.sendall((" ".join(a.cmd) + "\n").encode())
        s.settimeout(a.timeout)
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    reply = buf.decode().rstrip("\n")
    print(reply)
    sys.exit(0 if reply.startswith("OK") else 1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="sub", required=True)

    n = sub.add_parser("node", help="run the client next to a hydra-node")
    n.add_argument("-api", default="127.0.0.1:4001", help="hydra-node API host:port")
    n.add_argument("-skey", default="", help="my funds signing key as a cardano-cli text envelope, or none for an observer")
    n.add_argument("-peer-vkey", default="", help="peer funds verification key")
    n.add_argument("-cardano-cli", default="", help="cardano-cli binary for deposit signing and L1 queries")
    n.add_argument("-socket", default="", help="node socket for L1 queries")
    n.add_argument("-magic", type=int, default=42)
    n.add_argument("-ctl", default="127.0.0.1:7200")
    n.add_argument("-workdir", default=".")
    n.add_argument("-min-utxo", type=int, default=1_000_000, help="lovelace floor for outputs")
    n.add_argument("-tx-timeout", type=float, default=120.0, help="seconds to wait for a payment to confirm")
    n.add_argument("-fanout-timeout", type=float, default=1800.0, help="seconds to wait for ReadyToFanout")
    n.set_defaults(fn=lambda a: Node(a).run())

    c = sub.add_parser("ctl", help="send a control command to a running node")
    c.add_argument("-addr", default="127.0.0.1:7200")
    c.add_argument("-timeout", type=float, default=3600)
    c.add_argument("cmd", nargs="+")
    c.set_defaults(fn=cmd_ctl)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
