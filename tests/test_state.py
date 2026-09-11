import tempfile
import unittest
from pathlib import Path

from lnmeshctl.state import Journal, StateError


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.journal = Journal(Path(self.tmp.name) / "journal.sqlite3")
        self.journal.upsert_node("n01", "10.77.0.2", "serial-1", "02:00:00:00:00:01", "SHA256:first")
        self.journal.upsert_node("n02", "10.77.0.3", "serial-2", "02:00:00:00:00:02", "SHA256:second")

    def tearDown(self):
        self.tmp.cleanup()

    def test_open_is_idempotent(self):
        first, created = self.journal.create_open("n01", "n02", 1_000, "regtest", True)
        second, repeated = self.journal.create_open("n01", "n02", 1_000, "regtest", True)
        self.assertTrue(created)
        self.assertFalse(repeated)
        self.assertEqual(first["id"], second["id"])

    def test_mainnet_cap_is_hard(self):
        with self.assertRaisesRegex(StateError, "hard 100000-sat cap"):
            self.journal.create_open("n01", "n02", 100_001, "bitcoin", False)

    def test_invalid_state_transition_is_rejected(self):
        op, _ = self.journal.create_open("n01", "n02", 1_000, "regtest", True)
        with self.assertRaisesRegex(StateError, "invalid transition"):
            self.journal.transition(op["id"], "ACTIVE", "skip lock-in")

    def test_node_registration_is_idempotent(self):
        first = self.journal.upsert_node("n03", "10.77.0.4", "serial-3", "02:00:00:00:00:03", "SHA256:third")
        second = self.journal.upsert_node("n03", "10.77.0.4", "serial-3", "02:00:00:00:00:03", "SHA256:third")
        self.assertEqual(first["name"], second["name"])
        self.assertEqual(len(self.journal.status()["nodes"]), 3)

    def test_node_address_must_match_name(self):
        with self.assertRaisesRegex(StateError, "does not match"):
            self.journal.upsert_node("n01", "10.77.0.3", "serial-1", "02:00:00:00:00:01", "SHA256:first")
