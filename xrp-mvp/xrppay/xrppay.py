#!/usr/bin/env python3
"""xrppay: minimum viable XRP Ledger payment channel node and watchtower for the
mesh testbed.

One node process runs on each leaf. A node can pay through one outgoing
channel and receive through one incoming channel at the same time. The node
reaches the ledger through the JSON-RPC port of the gateway. Claims travel to
the peer over a plain TCP link on the mesh, one JSON object per line. Control
commands arrive on a TCP port bound to localhost.

The tower process runs on the gateway. After every claim the payee pre-signs
the transaction that redeems the claim and closes the channel, and it hands the
signed blob to the tower. When the payer schedules the closure, the tower
submits the newest blob, so the payee is paid even while it is offline. The
blob spends a Ticket of the payee, so the payee's own transactions never
invalidate it. The tower holds no key, because the ledger accepts a claim only
from the source or the destination of the channel and the blob already carries
the signature of the payee.

Subcommands: keygen, fund, node, tower, ctl. Nothing here is production code.
"""
import argparse
import json
import os
import queue
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from decimal import Decimal

from xrpl.clients import JsonRpcClient
from xrpl.constants import CryptoAlgorithm
from xrpl.core import keypairs
from xrpl.core.binarycodec import encode_for_signing_claim
from xrpl.models.requests import AccountInfo, Ledger, LedgerEntry, ServerInfo, SubmitOnly, Tx
from xrpl.models.transactions import Payment, PaymentChannelClaim, PaymentChannelCreate, TicketCreate
from xrpl.models.transactions.payment_channel_claim import PaymentChannelClaimFlag
from xrpl.transaction import sign, submit_and_wait
from xrpl.utils import drops_to_xrp, ripple_time_to_posix, xrp_to_drops
from xrpl.wallet import Wallet

# The genesis account of a stand-alone ledger holds all 100 billion XRP and
# signs with a secp256k1 key.
GENESIS_SEED = "snoPBrXtMeMyMHUVTgbuqAfg1SUTb"
TF_CLOSE = int(PaymentChannelClaimFlag.TF_CLOSE)


def ts():
    return datetime.now(timezone.utc).strftime("%H:%M:%S.%f")[:-3]


def log(*a):
    print(ts(), *a, flush=True)


def now_ms():
    return time.monotonic() * 1000.0


def xrp(drops):
    """Formats an integer number of drops as a compact XRP string, for example 1000 as 0.001."""
    s = f"{drops_to_xrp(str(int(drops))):.6f}".rstrip("0").rstrip(".")
    return s if s not in ("", "-0") else "0"


def to_drops(amount_xrp):
    return int(xrp_to_drops(Decimal(str(amount_xrp))))


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


def load_wallet(path):
    with open(path) as f:
        d = json.load(f)
    alg = CryptoAlgorithm.SECP256K1 if d.get("algorithm") == "secp256k1" else CryptoAlgorithm.ED25519
    return Wallet.from_seed(d["seed"], algorithm=alg)


def created_entry(meta, kind):
    for n in meta.get("AffectedNodes", []):
        c = n.get("CreatedNode")
        if c and c.get("LedgerEntryType") == kind:
            return c
    raise RuntimeError(f"transaction created no {kind}")


def claim_message(channel, drops):
    return bytes.fromhex(encode_for_signing_claim({"channel": channel, "amount": str(int(drops))}))


def tx_fee(res):
    """Returns the fee of a validated transaction result. API version 2 nests the transaction fields under tx_json."""
    return int(res.get("Fee") or res.get("tx_json", {}).get("Fee") or 0)


def rpc(client, request):
    r = client.request(request)
    if not r.is_successful():
        raise RuntimeError(f"rpc {r.result.get('error')}: {r.result.get('error_message', '')}")
    return r.result


def ledger_now(client):
    lg = rpc(client, Ledger(ledger_index="validated"))["ledger"]
    return int(lg["ledger_index"]), int(lg["close_time"])


def chan_entry(client, channel):
    r = client.request(LedgerEntry(payment_channel=channel, ledger_index="validated"))
    if not r.is_successful():
        if r.result.get("error") == "entryNotFound":
            return None
        raise RuntimeError(f"rpc {r.result.get('error')}: {r.result.get('error_message', '')}")
    return r.result["node"]


def send_json(host, m, timeout=5.0):
    with socket.create_connection(host, timeout=timeout) as s:
        s.sendall((json.dumps(m) + "\n").encode())
        return json.loads(readline(s))


class State:
    """The node writes this JSON file atomically and syncs it to disk. Claims are
    money, so the payee persists a claim before it acknowledges the claim."""

    def __init__(self, path, default):
        self.path = path
        self.d = default
        if os.path.exists(path):
            with open(path) as f:
                self.d = json.load(f)

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.d, f, indent=1)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)
        dfd = os.open(os.path.dirname(os.path.abspath(self.path)), os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)


class Node:
    def __init__(self, args):
        self.args = args
        self.wallet = load_wallet(args.key)
        with open(args.peer) as f:
            peer = json.load(f)
        self.peer_addr = peer["address"]
        self.peer_host = hostport(args.peer_host)
        self.client = JsonRpcClient(args.rpc)
        self.state = State(args.state, {"out": None, "in": None})
        self.lock = threading.RLock()        # guards the state
        self.chain_lock = threading.Lock()   # one on-chain submission at a time, because the account Sequence must grow in order
        self.redeem_lock = threading.Lock()  # one redeem at a time, and the watcher stays quiet meanwhile
        self.watch_last = "never polled"
        self.chain_down_logged = False
        self.tower = hostport(args.tower) if args.tower else None
        self.tower_q = queue.Queue()

    # ---------------- chain helpers ----------------
    def req(self, request):
        return rpc(self.client, request)

    def ledger_now(self):
        return ledger_now(self.client)

    def account_drops(self, addr=None):
        r = self.req(AccountInfo(account=addr or self.wallet.address, ledger_index="validated"))
        return int(r["account_data"]["Balance"])

    def chan_entry(self, channel):
        return chan_entry(self.client, channel)

    def submit(self, tx):
        """Signs the transaction locally, submits it through the gateway and waits
        for a validated ledger. Returns the transaction result with its metadata
        and the elapsed milliseconds, and raises on failure."""
        t0 = now_ms()
        with self.chain_lock:
            resp = submit_and_wait(tx, self.client, self.wallet)
        return resp.result, now_ms() - t0

    # ---------------- peer link ----------------
    def peer_send(self, m, timeout=5.0):
        return send_json(self.peer_host, m, timeout)

    def peer_server(self, listen):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(listen)
        srv.listen(16)
        log(f"peer link listening on {listen[0]}:{listen[1]}")
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=self.handle_peer, args=(conn,), daemon=True).start()

    def handle_peer(self, conn):
        with conn:
            try:
                conn.settimeout(10)
                m = json.loads(readline(conn))
                t = m.get("t")
                if t == "claim":
                    reply = self.on_claim(m)
                elif t == "chan_open":
                    reply = self.on_chan_open(m)
                elif t == "ping":
                    reply = {"ok": True}
                else:
                    reply = {"ok": False, "err": "unknown message"}
            except Exception as e:  # noqa: BLE001
                reply = {"ok": False, "err": f"{type(e).__name__}: {e}"}
            try:
                conn.sendall((json.dumps(reply) + "\n").encode())
            except OSError:
                pass

    def on_chan_open(self, m):
        chan = m["channel"]
        node = self.chan_entry(chan)
        if node is None:
            return {"ok": False, "err": "channel not on ledger"}
        if node.get("Destination") != self.wallet.address or node.get("Account") != self.peer_addr:
            return {"ok": False, "err": "channel parties mismatch"}
        with self.lock:
            self.state.d["in"] = {
                "channel": chan, "payer": node["Account"], "payer_pub": node["PublicKey"],
                "funded_drops": int(node["Amount"]), "settle_delay": int(node["SettleDelay"]),
                "best_drops": 0, "best_sig": None, "version": 0, "redeemed_drops": 0, "closed": False,
                "ticket": None, "tower_drops": 0,
            }
            self.state.save()
        log(f"IN channel {chan} from {node['Account']} funded {xrp(node['Amount'])} XRP settle {node['SettleDelay']}s")
        self.tower_notify()
        return {"ok": True}

    def on_claim(self, m):
        t0 = now_ms()
        with self.lock:
            inn = self.state.d["in"]
            if not inn:
                return {"ok": False, "err": "no incoming channel"}
            if m.get("channel") != inn["channel"]:
                return {"ok": False, "err": "unknown channel"}
            amt = int(m["amount"])
            if amt <= inn["best_drops"]:
                return {"ok": False, "err": f"stale claim {amt} <= {inn['best_drops']}"}
            if amt > inn["funded_drops"]:
                log(f"CLAIM rejected: {xrp(amt)} XRP exceeds channel funding {xrp(inn['funded_drops'])} XRP")
                return {"ok": False, "err": f"claim {amt} exceeds channel funding {inn['funded_drops']}"}
            try:
                ok = keypairs.is_valid_message(claim_message(inn["channel"], amt), bytes.fromhex(m["sig"]), inn["payer_pub"])
            except Exception:  # noqa: BLE001
                ok = False
            t_ver = now_ms() - t0
            if not ok:
                log("CLAIM rejected: bad signature")
                return {"ok": False, "err": "bad signature"}
            delta = amt - inn["best_drops"]
            inn["best_drops"] = amt
            inn["best_sig"] = m["sig"]
            inn["version"] += 1
            self.state.save()
        log(f"CLAIM v{inn['version']} +{xrp(delta)} total {xrp(amt)} XRP, verify {t_ver:.1f} ms, handled {now_ms() - t0:.1f} ms")
        self.tower_notify()
        return {"ok": True, "amount": str(amt), "version": inn["version"]}

    # ---------------- tower side of the payee ----------------
    def tower_notify(self):
        if self.tower:
            self.tower_q.put(1)

    def tower_send(self, m):
        return send_json(self.tower, m)

    def tower_loop(self):
        """Runs in the background, so the payee acknowledges a claim before the
        tower learns about it. Only the newest claim matters, so queued
        notifications collapse into one push."""
        while True:
            self.tower_q.get()
            while not self.tower_q.empty():
                self.tower_q.get()
            try:
                self.tower_push()
            except Exception as e:  # noqa: BLE001
                log(f"TOWER push failed: {type(e).__name__}: {e}")
                time.sleep(2)
                self.tower_q.put(1)

    def tower_push(self):
        with self.lock:
            inn = self.state.d["in"]
            if not inn or inn.get("closed"):
                return
            ticket = inn.get("ticket")
        if ticket is None:
            # One Ticket per channel reserves a sequence number for the tower's
            # blob, so the payee's own transactions never invalidate the blob.
            res, ms = self.submit(TicketCreate(account=self.wallet.address, ticket_count=1))
            ticket = int(created_entry(res["meta"], "Ticket")["NewFields"]["TicketSequence"])
            with self.lock:
                inn["ticket"] = ticket
                self.state.save()
            log(f"TOWER ticket {ticket} reserved in ledger {res.get('ledger_index')} ({ms:.0f} ms)")
        with self.lock:
            amt, sig, pub, chan = inn["best_drops"], inn["best_sig"], inn["payer_pub"], inn["channel"]
            if amt <= inn.get("tower_drops", 0) or not sig:
                return
        t0 = now_ms()
        tx = PaymentChannelClaim(account=self.wallet.address, channel=chan, balance=str(amt), amount=str(amt),
                                 signature=sig, public_key=pub, flags=TF_CLOSE, ticket_sequence=ticket, sequence=0,
                                 fee=str(self.args.tower_fee))
        signed = sign(tx, self.wallet)
        t_sign = now_ms() - t0
        reply = self.tower_send({"t": "claim", "channel": chan, "payee": self.wallet.address, "amount": str(amt),
                                 "ticket": ticket, "blob": signed.blob(), "hash": signed.get_hash()})
        if not reply.get("ok"):
            raise RuntimeError(f"tower refused: {reply.get('err')}")
        with self.lock:
            inn["tower_drops"] = max(inn.get("tower_drops", 0), amt)
            self.state.save()
        log(f"TOWER holds claim {xrp(amt)} XRP (presign {t_sign:.1f} ms, round trip {now_ms() - t0:.0f} ms)")

    def tower_status(self):
        with self.lock:
            inn = self.state.d["in"]
        if not self.tower or not inn:
            return {}
        try:
            return self.tower_send({"t": "status", "channel": inn["channel"]})
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "err": f"{type(e).__name__}: {e}"}

    # ---------------- payer side ----------------
    def cmd_open(self, amount_xrp, settle):
        with self.lock:
            if self.state.d["out"]:
                return "ERR outgoing channel already exists"
        drops = to_drops(amount_xrp)
        tx = PaymentChannelCreate(account=self.wallet.address, amount=str(drops), destination=self.peer_addr,
                                  settle_delay=int(settle), public_key=self.wallet.public_key)
        res, ms = self.submit(tx)
        chan = created_entry(res["meta"], "PayChannel")["LedgerIndex"]
        with self.lock:
            self.state.d["out"] = {
                "channel": chan, "payee": self.peer_addr, "funded_drops": drops, "signed_drops": 0,
                "version": 0, "settle_delay": int(settle), "open_ledger": res.get("ledger_index"),
                "open_tx": res.get("hash"), "closed": False,
            }
            self.state.save()
        log(f"OUT channel {chan} to {self.peer_addr} funded {amount_xrp} XRP settle {settle}s ({ms:.0f} ms)")
        try:
            reply = self.peer_send({"t": "chan_open", "channel": chan, "payer": self.wallet.address})
        except Exception as e:  # noqa: BLE001
            reply = {"ok": False, "err": str(e)}
        return (f"OK channel {chan} funded {amount_xrp} XRP settle {settle}s ledger {res.get('ledger_index')} "
                f"chain {ms:.0f} ms peer_ack {'ok' if reply.get('ok') else reply.get('err')}")

    def cmd_pay(self, amount_xrp, force=False):
        t0 = now_ms()
        with self.lock:
            out = self.state.d["out"]
            if not out:
                return "ERR no outgoing channel"
            drops = to_drops(amount_xrp)
            total = out["signed_drops"] + drops
            if total > out["funded_drops"] and not force:
                return f"ERR insufficient channel funds: want {xrp(total)} XRP, funded {xrp(out['funded_drops'])} XRP"
            prev = (out["signed_drops"], out["version"], out.get("last_sig"))
            sig = keypairs.sign(claim_message(out["channel"], total), self.wallet.private_key)
            t_sign = now_ms() - t0
            out["signed_drops"] = total
            out["version"] += 1
            out["last_sig"] = sig
            self.state.save()          # the saved counter prevents a lower cumulative amount after a restart
            msg = {"t": "claim", "channel": out["channel"], "amount": str(total), "sig": sig,
                   "pub": self.wallet.public_key, "version": out["version"]}
        try:
            reply = self.peer_send(msg)
        except Exception as e:  # noqa: BLE001
            return f"ERR peer unreachable ({type(e).__name__}: {e}); claim v{out['version']} kept locally"
        ms = now_ms() - t0
        if reply.get("ok"):
            return f"OK paid {amount_xrp} XRP total {xrp(total)} XRP version {out['version']} in {ms:.0f} ms (sign {t_sign:.1f} ms)"
        with self.lock:   # the payee rejected the claim, so the payer rolls its counter back
            out["signed_drops"], out["version"], out["last_sig"] = prev
            self.state.save()
        return f"ERR payee rejected claim: {reply.get('err')} ({ms:.0f} ms)"

    def payer_close(self):
        with self.lock:
            out = self.state.d["out"]
            if not out:
                return "ERR no outgoing channel"
        t0 = now_ms()
        res, ms1 = self.submit(PaymentChannelClaim(account=self.wallet.address, channel=out["channel"], flags=TF_CLOSE))
        entry = self.chan_entry(out["channel"])
        if entry is None:
            with self.lock:
                out["closed"] = True
                self.state.save()
            return f"OK channel closed immediately (nothing owed) in {ms1:.0f} ms ledger {res.get('ledger_index')}"
        exp = int(entry["Expiration"])
        log(f"CLOSE requested; expiration {exp} = {datetime.fromtimestamp(ripple_time_to_posix(exp), timezone.utc).strftime('%H:%M:%S')}Z "
            f"(settle {out['settle_delay']}s); ledger {res.get('ledger_index')}; {ms1:.0f} ms")
        finals = 0
        while True:
            time.sleep(self.args.poll)
            entry = self.chan_entry(out["channel"])
            if entry is None:
                break
            idx, close_time = self.ledger_now()
            if close_time >= exp:
                finals += 1
                res2, ms2 = self.submit(PaymentChannelClaim(account=self.wallet.address, channel=out["channel"], flags=TF_CLOSE))
                log(f"CLOSE finalize attempt {finals}: {res2['meta']['TransactionResult']} ledger {res2.get('ledger_index')} ({ms2:.0f} ms)")
                if self.chan_entry(out["channel"]) is None:
                    break
        with self.lock:
            out["closed"] = True
            self.state.save()
        return f"OK channel closed after settle delay: request {ms1:.0f} ms, total {now_ms() - t0:.0f} ms, finalize txs {finals}"

    # ---------------- payee side ----------------
    def redeem(self, close=False, forge_drops=None):
        with self.redeem_lock:
            return self._redeem(close, forge_drops)

    def _redeem(self, close, forge_drops):
        with self.lock:
            inn = self.state.d["in"]
            if not inn:
                return "ERR no incoming channel"
            amt, sig, pub = inn["best_drops"], inn["best_sig"], inn["payer_pub"]
            if forge_drops is not None:            # the forge cheat claims more than the payer signed and signs with the payee's own key
                amt = forge_drops
                sig = keypairs.sign(claim_message(inn["channel"], amt), self.wallet.private_key)
                pub = self.wallet.public_key
            elif amt <= inn["redeemed_drops"] and not close:
                return "ERR nothing new to redeem"
        t0 = now_ms()
        before = self.account_drops()
        kw = dict(account=self.wallet.address, channel=inn["channel"], flags=TF_CLOSE if close else 0)
        if amt > 0 and sig:
            kw.update(balance=str(amt), amount=str(amt), signature=sig, public_key=pub)
        res, ms = self.submit(PaymentChannelClaim(**kw))
        after = self.account_drops()
        paid = after - before + tx_fee(res)
        gone = self.chan_entry(inn["channel"]) is None
        with self.lock:
            if paid > 0:
                inn["redeemed_drops"] = max(inn["redeemed_drops"], amt)
            if gone:
                inn["closed"] = True
            self.state.save()
        what = "redeem+close" if close else "redeem"
        return (f"OK {what} claim {xrp(amt)} XRP: paid out {xrp(paid)} XRP, channel {'closed' if gone else 'open'}, "
                f"{res['meta']['TransactionResult']} ledger {res.get('ledger_index')} in {ms:.0f} ms (total {now_ms() - t0:.0f} ms)")

    def watcher(self):
        while True:
            time.sleep(self.args.poll)
            if self.redeem_lock.locked():
                continue
            with self.lock:
                inn = self.state.d["in"]
                if not inn or inn.get("closed"):
                    continue
                channel, best, redeemed = inn["channel"], inn["best_drops"], inn["redeemed_drops"]
            try:
                entry = self.chan_entry(channel)
                idx, close_time = self.ledger_now()
            except Exception as e:  # noqa: BLE001
                if not self.chain_down_logged:
                    log(f"WATCHER chain unreachable: {type(e).__name__}: {e}")
                    self.chain_down_logged = True
                self.watch_last = f"{ts()} chain unreachable"
                continue
            if self.chain_down_logged:
                log("WATCHER chain reachable again")
                self.chain_down_logged = False
            if entry is None:
                st = self.tower_status()
                with self.lock:
                    inn["closed"] = True
                    if st.get("result") == "tesSUCCESS":
                        inn["redeemed_drops"] = max(inn["redeemed_drops"], int(st["amount"]))
                    unredeemed = inn["best_drops"] - inn["redeemed_drops"]
                    self.state.save()
                if st.get("result") == "tesSUCCESS":
                    log(f"WATCHER channel {channel[:8]} gone from ledger (ledger {idx}); the tower redeemed "
                        f"{xrp(st['amount'])} XRP for me in ledger {st.get('ledger')} ({str(st.get('hash'))[:16]})")
                else:
                    log(f"WATCHER channel {channel[:8]} gone from ledger (ledger {idx}); unredeemed {xrp(unredeemed)} XRP")
                self.watch_last = f"{ts()} channel gone at ledger {idx}"
                continue
            exp = entry.get("Expiration")
            with self.lock:
                inn["funded_drops"] = int(entry["Amount"])
            self.watch_last = (f"{ts()} ledger {idx} close_time {close_time} amount {xrp(entry['Amount'])} "
                               f"balance {xrp(entry['Balance'])} expiration {exp}")
            if exp is not None and best > redeemed:
                log(f"WATCHER payer scheduled close (expiration {exp}, ledger close_time {close_time}); "
                    f"redeeming best claim {xrp(best)} XRP with close")
                try:
                    log("WATCHER", self.redeem(close=True))
                except Exception as e:  # noqa: BLE001
                    log(f"WATCHER redeem failed: {type(e).__name__}: {e}")

    # ---------------- control ----------------
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
                conn.settimeout(600)
                argv = readline(conn).split()
                log("ctl", " ".join(argv))
                reply = self.dispatch(argv)
            except Exception as e:  # noqa: BLE001
                reply = f"ERR {type(e).__name__}: {e}"
            log("ctl reply:", reply.replace("\n", " | "))
            try:
                conn.sendall((reply + "\n").encode())
            except OSError:
                pass

    def dispatch(self, argv):
        if not argv:
            return "ERR empty command"
        cmd, a = argv[0], argv[1:]
        if cmd == "ping":
            return "OK pong"
        if cmd == "info":
            return self.cmd_info()
        if cmd == "onchain":
            idx, ct = self.ledger_now()
            return f"OK {xrp(self.account_drops())} XRP ledger {idx} close_time {ct}"
        if cmd == "ledger":
            idx, ct = self.ledger_now()
            return f"OK ledger {idx} close_time {ct} ({datetime.fromtimestamp(ripple_time_to_posix(ct), timezone.utc).strftime('%H:%M:%S')}Z)"
        if cmd == "open":
            return self.cmd_open(a[0], a[1] if len(a) > 1 else 60)
        if cmd == "pay":
            return self.cmd_pay(a[0], force=(len(a) > 1 and a[1] == "force"))
        if cmd == "bal":
            return self.cmd_bal()
        if cmd == "redeem":
            return self.redeem(close=False)
        if cmd == "forge":
            return self.redeem(close=False, forge_drops=to_drops(a[0]))
        if cmd == "close":
            which = a[0] if a else ("in" if self.state.d["in"] and not self.state.d["in"].get("closed") else "out")
            return self.redeem(close=True) if which == "in" else self.payer_close()
        if cmd == "chan":
            return self.cmd_chan(a[0] if a else None)
        if cmd == "watch":
            return "OK " + self.watch_last
        if cmd == "tower":
            return "OK " + json.dumps(self.tower_status())
        if cmd == "peerping":
            t0 = now_ms()
            r = self.peer_send({"t": "ping"})
            return f"OK peer {r} in {now_ms() - t0:.1f} ms"
        return f"ERR unknown command {cmd}"

    def cmd_info(self):
        lines = [f"OK address {self.wallet.address}", f"pubkey {self.wallet.public_key}", f"rpc {self.args.rpc}",
                 f"peer {self.peer_addr} at {self.peer_host[0]}:{self.peer_host[1]}", f"state {self.args.state}",
                 f"tower {self.args.tower or 'none'}"]
        try:
            si = self.req(ServerInfo())["info"]
            lines.append(f"server {si.get('build_version')} ledger {si.get('validated_ledger', {}).get('seq')} "
                         f"complete_ledgers {si.get('complete_ledgers')}")
        except Exception as e:  # noqa: BLE001
            lines.append(f"chain unreachable: {type(e).__name__}")
        return "\n".join(lines)

    def cmd_bal(self):
        lines = ["OK"]
        out, inn = self.state.d["out"], self.state.d["in"]
        if out:
            lines.append(f"out channel {out['channel']} funded {xrp(out['funded_drops'])} sent {xrp(out['signed_drops'])} "
                         f"remaining {xrp(out['funded_drops'] - out['signed_drops'])} version {out['version']}"
                         f"{' CLOSED' if out.get('closed') else ''}")
        else:
            lines.append("out none")
        if inn:
            lines.append(f"in channel {inn['channel']} funded {xrp(inn['funded_drops'])} received {xrp(inn['best_drops'])} "
                         f"redeemed {xrp(inn['redeemed_drops'])} unredeemed {xrp(inn['best_drops'] - inn['redeemed_drops'])} "
                         f"version {inn['version']} tower {xrp(inn.get('tower_drops', 0))} ticket {inn.get('ticket')}"
                         f"{' CLOSED' if inn.get('closed') else ''}")
        else:
            lines.append("in none")
        return "\n".join(lines)

    def cmd_chan(self, which):
        which = which or ("in" if self.state.d["in"] else "out")
        c = self.state.d.get(which)
        if not c:
            return f"ERR no {which} channel"
        e = self.chan_entry(c["channel"])
        idx, ct = self.ledger_now()
        if e is None:
            return f"OK {which} channel {c['channel']} not on ledger (ledger {idx} close_time {ct})"
        return (f"OK {which} channel {c['channel']} amount {xrp(e['Amount'])} balance {xrp(e['Balance'])} "
                f"settle {e['SettleDelay']} expiration {e.get('Expiration')} cancel_after {e.get('CancelAfter')} "
                f"ledger {idx} close_time {ct}")

    def run(self):
        log(f"xrppay node {self.wallet.address} peer {self.peer_addr} rpc {self.args.rpc} tower {self.args.tower or 'none'}")
        threading.Thread(target=self.peer_server, args=(hostport(self.args.listen),), daemon=True).start()
        threading.Thread(target=self.ctl_server, args=(hostport(self.args.ctl),), daemon=True).start()
        threading.Thread(target=self.watcher, daemon=True).start()
        if self.tower:
            threading.Thread(target=self.tower_loop, daemon=True).start()
            self.tower_notify()   # after a restart the node hands the tower the newest claim in its state file
        log("node ready")
        while True:
            time.sleep(3600)


class Tower:
    """The watchtower of the XRP arm. It runs on the gateway and keeps the newest
    pre-signed claim-and-close transaction of every payee, one per channel. It
    watches every channel on the ledger and submits the blob as soon as the
    payer has scheduled the closure. It needs no key of its own."""

    def __init__(self, args):
        self.args = args
        self.client = JsonRpcClient(args.rpc)
        self.state = State(args.state, {"channels": {}})
        self.lock = threading.RLock()
        self.chain_down_logged = False

    def serve(self, listen):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(listen)
        srv.listen(16)
        log(f"tower listening on {listen[0]}:{listen[1]}")
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        with conn:
            try:
                conn.settimeout(10)
                m = json.loads(readline(conn))
                reply = self.on_message(m)
            except Exception as e:  # noqa: BLE001
                reply = {"ok": False, "err": f"{type(e).__name__}: {e}"}
            try:
                conn.sendall((json.dumps(reply) + "\n").encode())
            except OSError:
                pass

    def on_message(self, m):
        chans = self.state.d["channels"]
        if m.get("t") == "claim":
            amt = int(m["amount"])
            with self.lock:
                rec = chans.get(m["channel"])
                if rec and int(rec["amount"]) >= amt and not rec.get("done"):
                    return {"ok": True, "amount": rec["amount"], "note": "already held"}
                chans[m["channel"]] = {"payee": m["payee"], "amount": str(amt), "ticket": m.get("ticket"),
                                       "blob": m["blob"], "hash": m["hash"], "received": ts(),
                                       "submitted": False, "done": False}
                self.state.save()
            log(f"HOLD channel {m['channel'][:8]} payee {m['payee']} claim {xrp(amt)} XRP ticket {m.get('ticket')} blob {len(m['blob']) // 2} bytes")
            return {"ok": True, "amount": str(amt)}
        if m.get("t") == "status":
            rec = chans.get(m.get("channel"))
            if not rec:
                return {"ok": False, "err": "unknown channel"}
            return {"ok": True, **{k: v for k, v in rec.items() if k != "blob"}}
        return {"ok": False, "err": "unknown message"}

    def loop(self):
        while True:
            time.sleep(self.args.poll)
            with self.lock:
                items = [(c, dict(r)) for c, r in self.state.d["channels"].items() if not r.get("done")]
            for chan, rec in items:
                try:
                    entry = chan_entry(self.client, chan)
                    idx, close_time = ledger_now(self.client)
                except Exception as e:  # noqa: BLE001
                    if not self.chain_down_logged:
                        log(f"WATCH chain unreachable: {type(e).__name__}: {e}")
                        self.chain_down_logged = True
                    break
                if self.chain_down_logged:
                    log("WATCH chain reachable again")
                    self.chain_down_logged = False
                if entry is None:
                    with self.lock:
                        r = self.state.d["channels"][chan]
                        r["done"] = True
                        r["gone_ledger"] = idx
                        self.state.save()
                    log(f"WATCH channel {chan[:8]} gone from ledger (ledger {idx}), submitted {rec.get('submitted')}")
                    continue
                exp = entry.get("Expiration")
                if exp is not None and int(rec["amount"]) > int(entry["Balance"]) and not rec.get("submitted"):
                    log(f"WATCH payer scheduled close of {chan[:8]} (expiration {exp}, ledger {idx} close_time {close_time}); "
                        f"submitting the payee's claim {xrp(rec['amount'])} XRP")
                    self.submit_blob(chan)

    def submit_blob(self, chan):
        t0 = now_ms()
        with self.lock:
            rec = self.state.d["channels"][chan]
            blob, h = rec["blob"], rec["hash"]
            rec["submitted"] = True
            rec["submit_ts"] = ts()
            self.state.save()
        r = self.client.request(SubmitOnly(tx_blob=blob))
        eng = r.result.get("engine_result") or r.result.get("error")
        log(f"SUBMIT {h[:16]}: {eng} ({now_ms() - t0:.0f} ms)")
        for _ in range(40):
            time.sleep(1)
            tr = self.client.request(Tx(transaction=h))
            if tr.is_successful() and tr.result.get("validated"):
                result = tr.result.get("meta", {}).get("TransactionResult")
                li = tr.result.get("ledger_index")
                with self.lock:
                    rec = self.state.d["channels"][chan]
                    rec["result"], rec["ledger"] = result, li
                    rec["done"] = result == "tesSUCCESS"
                    self.state.save()
                log(f"VALIDATED {h[:16]} {result} ledger {li}, {now_ms() - t0:.0f} ms after the submission")
                return
        log(f"SUBMIT {h[:16]} not validated within 40 s ({eng})")

    def run(self):
        log(f"xrppay tower rpc {self.args.rpc} state {self.args.state} holding {len(self.state.d['channels'])} channel(s)")
        threading.Thread(target=self.serve, args=(hostport(self.args.listen),), daemon=True).start()
        self.loop()


# ---------------- one-shot subcommands ----------------
def cmd_keygen(a):
    w = Wallet.create(CryptoAlgorithm.ED25519)
    with open(a.out, "w") as f:
        json.dump({"seed": w.seed, "algorithm": "ed25519", "address": w.address, "public_key": w.public_key}, f, indent=1)
    os.chmod(a.out, 0o600)
    with open(a.pub, "w") as f:
        json.dump({"address": w.address, "public_key": w.public_key}, f, indent=1)
    print(f"{a.out}: {w.address} {w.public_key}")


def cmd_fund(a):
    client = JsonRpcClient(a.rpc)
    genesis = Wallet.from_seed(a.genesis_seed, algorithm=CryptoAlgorithm.SECP256K1)
    tx = Payment(account=genesis.address, destination=a.to, amount=str(to_drops(a.xrp)))
    t0 = now_ms()
    r = submit_and_wait(tx, client, genesis)
    print(f"funded {a.to} with {a.xrp} XRP from {genesis.address}: {r.result['meta']['TransactionResult']} "
          f"ledger {r.result.get('ledger_index')} in {now_ms() - t0:.0f} ms")
    r = client.request(AccountInfo(account=a.to, ledger_index="validated"))
    print("balance", xrp(r.result["account_data"]["Balance"]), "XRP")


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

    k = sub.add_parser("keygen", help="create an ed25519 wallet file and a public peer file")
    k.add_argument("-out", required=True)
    k.add_argument("-pub", required=True)
    k.set_defaults(fn=cmd_keygen)

    f = sub.add_parser("fund", help="fund an account from the stand-alone genesis account")
    f.add_argument("-rpc", required=True)
    f.add_argument("-to", required=True, help="destination address")
    f.add_argument("-xrp", default="10000")
    f.add_argument("-genesis-seed", default=GENESIS_SEED)
    f.set_defaults(fn=cmd_fund)

    n = sub.add_parser("node", help="run the channel node")
    n.add_argument("-rpc", required=True, help="JSON-RPC URL through the gateway")
    n.add_argument("-key", required=True, help="my wallet file")
    n.add_argument("-peer", required=True, help="peer public file (address, public_key)")
    n.add_argument("-peer-host", required=True, help="peer link host:port over the mesh")
    n.add_argument("-listen", default="0.0.0.0:6100")
    n.add_argument("-ctl", default="127.0.0.1:7100")
    n.add_argument("-state", default="state.json")
    n.add_argument("-poll", type=float, default=2.0, help="watcher poll interval in seconds")
    n.add_argument("-tower", default="", help="gateway tower host:port, or empty to run without a tower")
    n.add_argument("-tower-fee", type=int, default=10, help="fee in drops of the pre-signed claim")
    n.set_defaults(fn=lambda a: Node(a).run())

    t = sub.add_parser("tower", help="run the gateway watchtower")
    t.add_argument("-rpc", default="http://127.0.0.1:5005")
    t.add_argument("-listen", default="0.0.0.0:6600")
    t.add_argument("-state", default="tower.json")
    t.add_argument("-poll", type=float, default=2.0)
    t.set_defaults(fn=lambda a: Tower(a).run())

    c = sub.add_parser("ctl", help="send a control command to a running node")
    c.add_argument("-addr", default="127.0.0.1:7100")
    c.add_argument("-timeout", type=float, default=600)
    c.add_argument("cmd", nargs="+")
    c.set_defaults(fn=cmd_ctl)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
