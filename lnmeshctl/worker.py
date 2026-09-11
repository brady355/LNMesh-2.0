"""Idempotent gateway reconciler for staged one-sided channel openings."""

from __future__ import annotations

import argparse
import base64
import http.client
import json
import re
import subprocess
import time
from pathlib import Path
from typing import Any

from .state import Journal, StateError, TERMINAL


class RetryLater(RuntimeError):
    pass


def safe_error(error: Exception) -> str:
    text = re.sub(r"[A-Za-z0-9+/=]{100,}", "[redacted]", str(error))
    return text[:500]


class LeafRPC:
    def __init__(self, journal: Journal) -> None:
        self.inventory = {node["name"]: node for node in journal.status()["nodes"]}

    def call(self, node: str, method: str, params: dict[str, Any] | list[Any] | None = None) -> Any:
        record = self.inventory.get(node)
        if not record:
            raise StateError(f"unknown or unenrolled node {node}")
        command = [
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=/etc/lnmesh/known_hosts",
            "-i", f"/etc/lnmesh/keys/{node}-control", f"root@{record['mesh_ip']}", "rpc",
        ]
        request = json.dumps({"method": method, "params": params or {}}, separators=(",", ":"))
        result = subprocess.run(command, input=request, text=True, capture_output=True, timeout=180)
        output = result.stdout.strip() or result.stderr.strip()
        if result.returncode:
            try:
                decoded = json.loads(output)
                error = decoded.get("error", output)
                message = error.get("message", error) if isinstance(error, dict) else error
            except json.JSONDecodeError:
                message = output
            raise RetryLater(f"{node} {method}: {message}")
        return json.loads(output)


class CoreRPC:
    def __init__(self, network: str) -> None:
        self.port = {"bitcoin": 8332, "regtest": 18443, "testnet4": 48332}[network]
        subdir = {"bitcoin": "", "regtest": "regtest", "testnet4": "testnet4"}[network]
        self.cookie = Path("/var/lib/bitcoin") / subdir / ".cookie"

    def call(self, method: str, params: list[Any] | None = None) -> Any:
        if not self.cookie.is_file():
            raise RetryLater("Bitcoin Core RPC cookie is not ready")
        credential = base64.b64encode(self.cookie.read_bytes().strip()).decode()
        body = json.dumps({"jsonrpc": "2.0", "id": "lnmesh", "method": method, "params": params or []})
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        try:
            connection.request("POST", "/", body, {"Authorization": f"Basic {credential}", "Content-Type": "application/json"})
            response = connection.getresponse()
            payload = json.loads(response.read())
        finally:
            connection.close()
        if payload.get("error"):
            raise RetryLater(f"Bitcoin Core {method}: {payload['error'].get('message', 'RPC error')}")
        return payload["result"]


class Reconciler:
    def __init__(self, journal: Journal) -> None:
        self.journal = journal
        self.leaves = LeafRPC(journal)

    def preflight(self, op: dict[str, Any], signed_psbt: str) -> None:
        core = CoreRPC(op["network"])
        chain = core.call("getblockchaininfo")
        if chain["initialblockdownload"] or chain["blocks"] != chain["headers"]:
            raise RetryLater("Bitcoin Core is not synchronized")
        if op["network"] != "regtest":
            network = core.call("getnetworkinfo")
            if not network["networkactive"] or network["connections"] < 1:
                raise RetryLater("Bitcoin Core has no active public-chain peer")
            header = core.call("getblockheader", [chain["bestblockhash"]])
            maximum_age = 7_200 if op["network"] == "bitcoin" else 86_400
            if int(time.time()) - header["time"] > maximum_age:
                raise RetryLater("Bitcoin Core chain tip is stale")
        for node in (op["node_from"], op["node_to"]):
            info = self.leaves.call(node, "getinfo")
            if info["blockheight"] != chain["blocks"]:
                raise RetryLater(f"{node} is not caught up with Bitcoin Core")
        finalized = core.call("finalizepsbt", [signed_psbt])
        if not finalized.get("complete"):
            raise StateError("staged funding PSBT is not fully signed")
        acceptance = core.call("testmempoolaccept", [[finalized["hex"]]])[0]
        if not acceptance["allowed"]:
            raise RetryLater(f"funding transaction rejected: {acceptance.get('reject-reason', 'unknown reason')}")

    def open(self, op: dict[str, Any]) -> dict[str, Any]:
        metadata = json.loads(op["metadata_json"])
        if op["state"] == "REQUESTED":
            destination = self.leaves.call(op["node_to"], "getinfo")
            self.leaves.call(op["node_from"], "connect", {
                "id": destination["id"], "host": self.leaves.inventory[op["node_to"]]["mesh_ip"], "port": 9735,
            })
            op = self.journal.update_operation(op["id"], metadata={"node_to_id": destination["id"]})
            op = self.journal.transition(op["id"], "PEER_CONNECTED", "private mesh peer connected")
            metadata = json.loads(op["metadata_json"])

        if op["state"] == "PEER_CONNECTED":
            started = self.leaves.call(op["node_from"], "fundchannel_start", {
                "id": metadata["node_to_id"], "amount": op["amount_sat"], "announce": False,
            })
            prepared = self.leaves.call(op["node_from"], "txprepare", {
                "outputs": [{started["funding_address"]: op["amount_sat"]}],
            })
            completed = self.leaves.call(op["node_from"], "fundchannel_complete", {
                "id": metadata["node_to_id"], "psbt": prepared["psbt"], "withhold": True,
            })
            op = self.journal.update_operation(op["id"], channel_id=completed["channel_id"], metadata={
                "unsigned_psbt": prepared["psbt"], "funding_txid": prepared["txid"],
            })
            op = self.journal.transition(op["id"], "COMMITMENTS_SECURED", "commitment transactions secured")
            metadata = json.loads(op["metadata_json"])

        if op["state"] == "COMMITMENTS_SECURED":
            signed = self.leaves.call(op["node_from"], "signpsbt", {"psbt": metadata["unsigned_psbt"]})
            op = self.journal.update_operation(op["id"], metadata={"signed_psbt": signed["signed_psbt"]})
            op = self.journal.transition(op["id"], "SIGNED_STAGED", "signed funding transaction durably staged")
            metadata = json.loads(op["metadata_json"])

        if op["state"] == "SIGNED_STAGED" and not op["stage_only"]:
            self.preflight(op, metadata["signed_psbt"])
            op = self.journal.transition(op["id"], "PUBLISHING", "reconnection gate passed")

        if op["state"] == "PUBLISHING":
            metadata = json.loads(op["metadata_json"])
            self.preflight(op, metadata["signed_psbt"])
            published = self.leaves.call(op["node_from"], "sendpsbt", {"psbt": metadata["signed_psbt"]})
            op = self.journal.update_operation(op["id"], metadata={"published_txid": published["txid"]})
            op = self.journal.transition(op["id"], "AWAITING_LOCKIN", "funding transaction published")

        if op["state"] == "AWAITING_LOCKIN":
            metadata = json.loads(op["metadata_json"])
            channels = self.leaves.call(op["node_from"], "listpeerchannels", {"id": metadata["node_to_id"]})
            for channel in channels.get("channels", []):
                if channel.get("channel_id") == op["channel_id"] and channel.get("state") == "CHANNELD_NORMAL":
                    op = self.journal.transition(op["id"], "ACTIVE", "channel reached CHANNELD_NORMAL")
                    break
        return op

    def find_channel(self, channel_id: str) -> tuple[str, dict[str, Any]]:
        for node in sorted(self.leaves.inventory):
            result = self.leaves.call(node, "listpeerchannels")
            for channel in result.get("channels", []):
                if channel_id in {channel.get("channel_id"), channel.get("short_channel_id")}:
                    return node, channel
        raise RetryLater(f"channel {channel_id} is not currently visible")

    def public_relay_active(self, network: str) -> bool:
        if network == "regtest":
            return True
        status = CoreRPC(network).call("getnetworkinfo")
        return bool(status["networkactive"] and status["connections"] > 0)

    def close(self, op: dict[str, Any], force: bool) -> dict[str, Any]:
        metadata = json.loads(op["metadata_json"])
        requested_state = "FORCE_CLOSE_REQUESTED" if force else "CLOSE_REQUESTED"
        if op["state"] == requested_state:
            owner, channel = self.find_channel(op["channel_id"])
            if channel.get("htlcs"):
                raise RetryLater("channel still has unresolved HTLCs")
            result = self.leaves.call(owner, "close", {
                "id": op["channel_id"], "unilateraltimeout": 1 if force else 0,
            })
            op = self.journal.update_operation(op["id"], metadata={
                "owner": owner,
                "close_type": result.get("type"),
                "closing_txids": result.get("txids", []),
            })
            if force:
                op = self.journal.transition(op["id"], "FORCE_CLOSING", "explicit force close submitted")
            elif self.public_relay_active(op["network"]):
                op = self.journal.transition(op["id"], "CLOSING", "cooperative close submitted")
            else:
                op = self.journal.transition(op["id"], "GATEWAY_MEMPOOL_STAGED", "cooperative close staged in gateway mempool")
            metadata = json.loads(op["metadata_json"])

        if op["state"] == "GATEWAY_MEMPOOL_STAGED" and self.public_relay_active(op["network"]):
            op = self.journal.transition(op["id"], "CLOSING", "gateway public relay restored")

        if op["state"] in {"CLOSING", "FORCE_CLOSING", "CSV_WAIT"}:
            owner = metadata.get("owner")
            if not owner:
                raise StateError("closing operation has no owning leaf")
            channels = self.leaves.call(owner, "listpeerchannels").get("channels", [])
            matching = [channel for channel in channels if op["channel_id"] in {channel.get("channel_id"), channel.get("short_channel_id")}]
            if force and op["state"] == "FORCE_CLOSING" and matching and matching[0].get("state") == "ONCHAIN":
                op = self.journal.transition(op["id"], "CSV_WAIT", "commitment confirmed; tracking delayed outputs")
            elif not matching:
                closing_txids = set(metadata.get("closing_txids", []))
                transactions = self.leaves.call(owner, "listtransactions").get("transactions", [])
                confirmed = {tx.get("hash") for tx in transactions if tx.get("blockheight", 0) > 0}
                if closing_txids and closing_txids.issubset(confirmed):
                    op = self.journal.transition(op["id"], "CLOSED", "closing transactions confirmed and channel removed")
                    self.journal.mark_channel_closed(op["channel_id"])
        return op

    def run(self, op: dict[str, Any]) -> dict[str, Any]:
        if Path("/var/lib/lnmesh/retention-interlock").exists():
            raise RetryLater("prune-retention interlock is active")
        if op["kind"] == "open":
            return self.open(op)
        if op["kind"] in {"close", "force-close"}:
            return self.close(op, force=op["kind"] == "force-close")
        return op


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="lnmesh-lifecycle-worker")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args(argv)
    journal = Journal()
    results: list[dict[str, Any]] = []
    for op in journal.list_operations():
        if op["kind"] not in {"open", "close", "force-close"}:
            continue
        if op["state"] in TERMINAL or (op["state"] == "SIGNED_STAGED" and op["stage_only"]):
            continue
        if not journal.acquire(op["id"]):
            break
        try:
            journal.update_operation(op["id"], increment_attempts=True, last_error=None)
            current = Reconciler(journal).run(journal.get(op["id"]))
            results.append({"id": current["id"], "state": current["state"]})
        except Exception as error:
            message = safe_error(error)
            journal.update_operation(op["id"], last_error=message)
            results.append({"id": op["id"], "state": op["state"], "retry": message})
        finally:
            journal.release(op["id"])
        break
    output = {"operations": results}
    print(json.dumps(output, sort_keys=True) if args.json else json.dumps(output, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
