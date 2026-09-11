import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from lnmeshctl.state import Journal
from lnmeshctl.worker import Reconciler


class FakeLeaves:
    def __init__(self, journal):
        self.inventory = {node["name"]: node for node in journal.status()["nodes"]}
        self.sent = False

    def call(self, node, method, params=None):
        if method == "getinfo":
            return {"id": f"id-{node}", "blockheight": 10}
        if method == "connect":
            return {"id": params["id"]}
        if method == "fundchannel_start":
            return {"funding_address": "bcrt1-test"}
        if method == "txprepare":
            return {"psbt": "unsigned", "txid": "funding-txid"}
        if method == "fundchannel_complete":
            return {"channel_id": "channel-1", "commitments_secured": True}
        if method == "signpsbt":
            return {"signed_psbt": "signed"}
        if method == "sendpsbt":
            self.sent = True
            return {"txid": "published-txid"}
        if method == "listpeerchannels":
            return {"channels": [{"channel_id": "channel-1", "state": "CHANNELD_NORMAL"}]}
        raise AssertionError(method)


class FakeCore:
    def __init__(self, network):
        self.network = network

    def call(self, method, params=None):
        if method == "getblockchaininfo":
            return {"initialblockdownload": False, "blocks": 10, "headers": 10, "bestblockhash": "best"}
        if method == "finalizepsbt":
            return {"complete": True, "hex": "rawtx"}
        if method == "testmempoolaccept":
            return [{"allowed": True}]
        raise AssertionError(method)


class FakeClosingLeaves:
    def __init__(self, journal):
        self.inventory = {node["name"]: node for node in journal.status()["nodes"]}
        self.closed = False

    def call(self, node, method, params=None):
        if method == "listpeerchannels":
            if self.closed:
                return {"channels": []}
            return {"channels": [{"channel_id": "channel-1", "state": "CHANNELD_NORMAL", "htlcs": []}]}
        if method == "close":
            self.closed = True
            return {"type": "mutual", "txids": ["close-txid"], "txs": ["raw"]}
        if method == "listtransactions":
            return {"transactions": [{"hash": "close-txid", "blockheight": 11}]}
        raise AssertionError(method)


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.journal = Journal(Path(self.tmp.name) / "journal.sqlite3")
        self.journal.upsert_node("n01", "10.77.0.2", "s1", "02:00:00:00:00:01", "f1")
        self.journal.upsert_node("n02", "10.77.0.3", "s2", "02:00:00:00:00:02", "f2")

    def tearDown(self):
        self.tmp.cleanup()

    @patch("lnmeshctl.worker.CoreRPC", FakeCore)
    @patch("lnmeshctl.worker.LeafRPC", FakeLeaves)
    def test_open_reaches_active_after_safe_publication(self):
        op, _ = self.journal.create_open("n01", "n02", 1_000, "regtest", False)
        reconciler = Reconciler(self.journal)
        result = reconciler.open(op)
        self.assertEqual(result["state"], "ACTIVE")
        self.assertTrue(reconciler.leaves.sent)

    @patch("lnmeshctl.worker.CoreRPC", FakeCore)
    @patch("lnmeshctl.worker.LeafRPC", FakeLeaves)
    def test_stage_only_stops_before_publication(self):
        op, _ = self.journal.create_open("n01", "n02", 1_000, "regtest", True)
        reconciler = Reconciler(self.journal)
        result = reconciler.open(op)
        self.assertEqual(result["state"], "SIGNED_STAGED")
        self.assertFalse(reconciler.leaves.sent)

    @patch("lnmeshctl.worker.LeafRPC", FakeClosingLeaves)
    def test_cooperative_close_tracks_confirmation(self):
        op, _ = self.journal.create_request("close", "regtest", {"channel_id": "channel-1"})
        result = Reconciler(self.journal).close(op, force=False)
        self.assertEqual(result["state"], "CLOSED")
