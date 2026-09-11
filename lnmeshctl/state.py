"""Durable, secret-free operation journal for LNMesh."""

from __future__ import annotations

import json
import os
import sqlite3
import uuid
from hashlib import sha256
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Iterator

TERMINAL = {"ACTIVE", "ABORTED", "CONFLICTED", "FAILED", "CLOSED", "COMPLETED"}
OPEN_TRANSITIONS = {
    "REQUESTED": {"PEER_CONNECTED", "ABORTED", "FAILED"},
    "PEER_CONNECTED": {"COMMITMENTS_SECURED", "ABORTED", "FAILED"},
    "COMMITMENTS_SECURED": {"SIGNED_STAGED", "ABORTED", "FAILED"},
    "SIGNED_STAGED": {"PUBLISHING", "ABORTED", "CONFLICTED", "FAILED"},
    "PUBLISHING": {"AWAITING_LOCKIN", "CONFLICTED", "FAILED"},
    "AWAITING_LOCKIN": {"ACTIVE", "CONFLICTED", "FAILED"},
}
CLOSE_TRANSITIONS = {
    "CLOSE_REQUESTED": {"GATEWAY_MEMPOOL_STAGED", "CLOSING", "FAILED"},
    "GATEWAY_MEMPOOL_STAGED": {"CLOSING", "FAILED"},
    "CLOSING": {"CLOSED", "FAILED"},
    "FORCE_CLOSE_REQUESTED": {"FORCE_CLOSING", "FAILED"},
    "FORCE_CLOSING": {"CSV_WAIT", "FAILED"},
    "CSV_WAIT": {"CLOSED", "FAILED"},
}


def utcnow() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class StateError(RuntimeError):
    pass


class Journal:
    """SQLite state store.  Rows contain public operational metadata only."""

    def __init__(self, path: str | Path | None = None) -> None:
        state_dir = Path(os.environ.get("LN_MESH_STATE_DIR", "/var/lib/lnmesh"))
        self.path = Path(path) if path else state_dir / "journal.sqlite3"
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.initialize()

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("PRAGMA busy_timeout=5000")
        return connection

    def initialize(self) -> None:
        db = self.connect()
        try:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS nodes (
                    name TEXT PRIMARY KEY,
                    mesh_ip TEXT UNIQUE NOT NULL,
                    serial TEXT UNIQUE,
                    mac TEXT UNIQUE,
                    ssh_fingerprint TEXT,
                    cln_node_id TEXT UNIQUE,
                    last_chain_height INTEGER,
                    backup_status TEXT NOT NULL DEFAULT 'UNVERIFIED',
                    protection_state TEXT NOT NULL DEFAULT 'UNPROTECTED',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS operations (
                    id TEXT PRIMARY KEY,
                    idempotency_key TEXT UNIQUE NOT NULL,
                    kind TEXT NOT NULL,
                    network TEXT NOT NULL,
                    node_from TEXT,
                    node_to TEXT,
                    amount_sat INTEGER,
                    channel_id TEXT,
                    state TEXT NOT NULL,
                    stage_only INTEGER NOT NULL DEFAULT 0,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS operation_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    operation_id TEXT NOT NULL REFERENCES operations(id),
                    state TEXT NOT NULL,
                    message TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS cluster_lock (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    operation_id TEXT NOT NULL REFERENCES operations(id),
                    acquired_at TEXT NOT NULL
                );
                """
            )
        finally:
            db.close()

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        db = self.connect()
        try:
            db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    def create_open(
        self, node_from: str, node_to: str, amount_sat: int, network: str, stage_only: bool
    ) -> tuple[dict[str, Any], bool]:
        if node_from == node_to:
            raise StateError("channel participants must be different")
        if amount_sat <= 0:
            raise StateError("amount-sat must be positive")
        if network == "bitcoin" and amount_sat > 100_000:
            raise StateError("mainnet channel amount exceeds the hard 100000-sat cap")
        pair = ":".join(sorted((node_from, node_to)))
        key = f"open:{network}:{pair}:{amount_sat}:{int(stage_only)}"
        now = utcnow()
        with self.transaction() as db:
            existing = db.execute("SELECT * FROM operations WHERE idempotency_key=?", (key,)).fetchone()
            if existing:
                return dict(existing), False
            known = {row["name"] for row in db.execute("SELECT name FROM nodes WHERE name IN (?,?)", (node_from, node_to))}
            missing = sorted({node_from, node_to} - known)
            if missing:
                raise StateError("unknown or unenrolled node(s): " + ", ".join(missing))
            active = db.execute(
                """SELECT id FROM operations WHERE kind='open' AND network=?
                   AND node_from IN (?, ?) AND node_to IN (?, ?)
                   AND state NOT IN ('ABORTED','CONFLICTED','FAILED','CLOSED')""",
                (network, node_from, node_to, node_from, node_to),
            ).fetchone()
            if active:
                raise StateError(f"pair already has lifecycle operation {active['id']}")
            operation_id = str(uuid.uuid4())
            db.execute(
                """INSERT INTO operations
                   (id,idempotency_key,kind,network,node_from,node_to,amount_sat,state,stage_only,created_at,updated_at)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                (operation_id, key, "open", network, node_from, node_to, amount_sat,
                 "REQUESTED", int(stage_only), now, now),
            )
            db.execute(
                "INSERT INTO operation_events(operation_id,state,message,created_at) VALUES (?,?,?,?)",
                (operation_id, "REQUESTED", "opening requested and durably journaled", now),
            )
            row = db.execute("SELECT * FROM operations WHERE id=?", (operation_id,)).fetchone()
            return dict(row), True

    def upsert_node(
        self, name: str, mesh_ip: str, serial: str, mac: str, ssh_fingerprint: str
    ) -> dict[str, Any]:
        if name not in {f"n{i:02d}" for i in range(1, 8)}:
            raise StateError("invalid leaf name")
        expected_ip = f"10.77.0.{int(name[-1]) + 1}"
        if mesh_ip != expected_ip:
            raise StateError("leaf address does not match its name")
        now = utcnow()
        with self.transaction() as db:
            db.execute(
                """INSERT INTO nodes(name,mesh_ip,serial,mac,ssh_fingerprint,created_at,updated_at)
                   VALUES (?,?,?,?,?,?,?)
                   ON CONFLICT(name) DO UPDATE SET mesh_ip=excluded.mesh_ip,
                     serial=excluded.serial,mac=excluded.mac,
                     ssh_fingerprint=excluded.ssh_fingerprint,updated_at=excluded.updated_at""",
                (name, mesh_ip, serial, mac, ssh_fingerprint, now, now),
            )
            return dict(db.execute("SELECT * FROM nodes WHERE name=?", (name,)).fetchone())

    def create_request(self, kind: str, network: str, metadata: dict[str, Any]) -> tuple[dict[str, Any], bool]:
        """Journal a non-opening request with deterministic retry identity."""
        canonical = json.dumps(metadata, sort_keys=True, separators=(",", ":"))
        key = f"{kind}:{network}:{sha256(canonical.encode()).hexdigest()}"
        now = utcnow()
        initial_state = {
            "close": "CLOSE_REQUESTED",
            "force-close": "FORCE_CLOSE_REQUESTED",
        }.get(kind, "REQUESTED")
        with self.transaction() as db:
            existing = db.execute("SELECT * FROM operations WHERE idempotency_key=?", (key,)).fetchone()
            if existing:
                return dict(existing), False
            operation_id = str(uuid.uuid4())
            db.execute(
                """INSERT INTO operations
                   (id,idempotency_key,kind,network,channel_id,state,metadata_json,created_at,updated_at)
                   VALUES (?,?,?,?,?,?,?,?,?)""",
                (operation_id, key, kind, network, metadata.get("channel_id"), initial_state, canonical, now, now),
            )
            db.execute(
                "INSERT INTO operation_events(operation_id,state,message,created_at) VALUES (?,?,?,?)",
                (operation_id, initial_state, f"{kind} requested and durably journaled", now),
            )
            return dict(db.execute("SELECT * FROM operations WHERE id=?", (operation_id,)).fetchone()), True

    def get(self, operation_id: str) -> dict[str, Any]:
        db = self.connect()
        try:
            row = db.execute("SELECT * FROM operations WHERE id=?", (operation_id,)).fetchone()
        finally:
            db.close()
        if not row:
            raise StateError(f"unknown operation {operation_id}")
        return dict(row)

    def list_operations(self) -> list[dict[str, Any]]:
        db = self.connect()
        try:
            return [dict(row) for row in db.execute("SELECT * FROM operations ORDER BY created_at DESC")]
        finally:
            db.close()

    def transition(self, operation_id: str, state: str, message: str) -> dict[str, Any]:
        now = utcnow()
        with self.transaction() as db:
            row = db.execute("SELECT * FROM operations WHERE id=?", (operation_id,)).fetchone()
            if not row:
                raise StateError(f"unknown operation {operation_id}")
            transitions = OPEN_TRANSITIONS if row["kind"] == "open" else CLOSE_TRANSITIONS
            if state not in transitions.get(row["state"], set()):
                raise StateError(f"invalid transition {row['state']} -> {state}")
            db.execute("UPDATE operations SET state=?,updated_at=? WHERE id=?", (state, now, operation_id))
            db.execute(
                "INSERT INTO operation_events(operation_id,state,message,created_at) VALUES (?,?,?,?)",
                (operation_id, state, message, now),
            )
            return dict(db.execute("SELECT * FROM operations WHERE id=?", (operation_id,)).fetchone())

    def finish_request(self, operation_id: str, message: str) -> dict[str, Any]:
        """Finish an installer/control request which does not use channel states."""
        now = utcnow()
        with self.transaction() as db:
            row = db.execute("SELECT * FROM operations WHERE id=?", (operation_id,)).fetchone()
            if not row:
                raise StateError(f"unknown operation {operation_id}")
            if row["state"] == "COMPLETED":
                return dict(row)
            if row["kind"] == "open":
                raise StateError("channel openings must follow the lifecycle state machine")
            db.execute("UPDATE operations SET state='COMPLETED',updated_at=? WHERE id=?", (now, operation_id))
            db.execute(
                "INSERT INTO operation_events(operation_id,state,message,created_at) VALUES (?,?,?,?)",
                (operation_id, "COMPLETED", message, now),
            )
            return dict(db.execute("SELECT * FROM operations WHERE id=?", (operation_id,)).fetchone())

    def update_operation(
        self,
        operation_id: str,
        *,
        metadata: dict[str, Any] | None = None,
        channel_id: str | None = None,
        last_error: str | None = None,
        increment_attempts: bool = False,
    ) -> dict[str, Any]:
        """Durably update recovery data without changing lifecycle state."""
        now = utcnow()
        with self.transaction() as db:
            row = db.execute("SELECT * FROM operations WHERE id=?", (operation_id,)).fetchone()
            if not row:
                raise StateError(f"unknown operation {operation_id}")
            merged = json.loads(row["metadata_json"])
            if metadata:
                merged.update(metadata)
            db.execute(
                """UPDATE operations SET metadata_json=?,channel_id=COALESCE(?,channel_id),
                   last_error=?,attempts=attempts+?,updated_at=? WHERE id=?""",
                (json.dumps(merged, sort_keys=True, separators=(",", ":")), channel_id,
                 last_error, int(increment_attempts), now, operation_id),
            )
            return dict(db.execute("SELECT * FROM operations WHERE id=?", (operation_id,)).fetchone())

    def acquire(self, operation_id: str) -> bool:
        with self.transaction() as db:
            current = db.execute("SELECT operation_id FROM cluster_lock WHERE singleton=1").fetchone()
            if current and current["operation_id"] != operation_id:
                return False
            if not current:
                db.execute(
                    "INSERT INTO cluster_lock(singleton,operation_id,acquired_at) VALUES (1,?,?)",
                    (operation_id, utcnow()),
                )
            return True

    def release(self, operation_id: str) -> None:
        with self.transaction() as db:
            db.execute("DELETE FROM cluster_lock WHERE singleton=1 AND operation_id=?", (operation_id,))

    def mark_channel_closed(self, channel_id: str) -> None:
        now = utcnow()
        with self.transaction() as db:
            rows = db.execute(
                "SELECT id FROM operations WHERE kind='open' AND channel_id=? AND state='ACTIVE'",
                (channel_id,),
            ).fetchall()
            for row in rows:
                db.execute("UPDATE operations SET state='CLOSED',updated_at=? WHERE id=?", (now, row["id"]))
                db.execute(
                    "INSERT INTO operation_events(operation_id,state,message,created_at) VALUES (?,?,?,?)",
                    (row["id"], "CLOSED", "associated channel closed", now),
                )

    def status(self) -> dict[str, Any]:
        db = self.connect()
        try:
            return {
                "nodes": [dict(r) for r in db.execute("SELECT * FROM nodes ORDER BY name")],
                "operations": [dict(r) for r in db.execute("SELECT * FROM operations ORDER BY created_at DESC")],
            }
        finally:
            db.close()

    def close(self) -> None:
        """Compatibility no-op; connections are scoped to every operation."""
