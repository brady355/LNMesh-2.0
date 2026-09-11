"""Operator CLI.  Mutations create durable journal records before any worker acts."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

from .state import Journal, StateError


def emit(value: Any, as_json: bool) -> None:
    if as_json:
        print(json.dumps(value, sort_keys=True))
    elif isinstance(value, dict) and "id" in value:
        print(value["id"])
    else:
        print(json.dumps(value, indent=2, sort_keys=True))


def public_operation(record: dict[str, Any]) -> dict[str, Any]:
    result = dict(record)
    metadata = json.loads(result.pop("metadata_json", "{}"))
    result.pop("idempotency_key", None)
    result["recovery_fields"] = sorted(metadata)
    return result


def public_status(status: dict[str, Any]) -> dict[str, Any]:
    return {"nodes": status["nodes"], "operations": [public_operation(op) for op in status["operations"]]}


def is_gateway() -> bool:
    return os.environ.get("LN_MESH_ROLE") == "gateway"


def wake_worker() -> None:
    if is_gateway():
        subprocess.run(["systemctl", "start", "--no-block", "lnmesh-lifecycle-worker.service"], check=False)


def bitcoin_cli(*arguments: str) -> str:
    result = subprocess.run(
        ["/usr/local/bin/bitcoin-cli", "-conf=/etc/lnmesh/bitcoin.conf", "-datadir=/var/lib/bitcoin", *arguments],
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout.strip()


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="lnmeshctl")
    p.add_argument("--json", action="store_true", help="emit structured JSON")
    p.add_argument("--network", default=os.environ.get("LN_MESH_NETWORK", "regtest"), choices=("regtest", "testnet4", "bitcoin"))
    sub = p.add_subparsers(dest="command", required=True)
    bootstrap = sub.add_parser("bootstrap")
    bootstrap.add_argument("--expect", type=int, required=True)
    sub.add_parser("status")
    node = sub.add_parser("node")
    node_sub = node.add_subparsers(dest="node_command", required=True)
    node_sub.add_parser("list")
    address = node_sub.add_parser("address")
    address.add_argument("node")
    register = node_sub.add_parser("register", help=argparse.SUPPRESS)
    register.add_argument("--name", required=True)
    register.add_argument("--address", required=True)
    register.add_argument("--serial", required=True)
    register.add_argument("--mac", required=True)
    register.add_argument("--ssh-fingerprint", required=True)
    channel = sub.add_parser("channel")
    channel_sub = channel.add_subparsers(dest="channel_command", required=True)
    open_ = channel_sub.add_parser("open")
    open_.add_argument("--from", dest="node_from", required=True)
    open_.add_argument("--to", dest="node_to", required=True)
    open_.add_argument("--amount-sat", type=int, required=True)
    open_.add_argument("--stage-only", action="store_true")
    publish = channel_sub.add_parser("publish")
    publish.add_argument("operation_id")
    for command in ("close", "force-close"):
        cp = channel_sub.add_parser(command)
        cp.add_argument("channel_id")
        if command == "force-close":
            cp.add_argument("--confirm", required=True)
    sub.add_parser("reconcile")
    outage = sub.add_parser("outage")
    outage.add_argument("action", choices=("start", "stop"))
    mine = sub.add_parser("regtest")
    mine_sub = mine.add_subparsers(dest="regtest_command", required=True)
    mine_cmd = mine_sub.add_parser("mine")
    mine_cmd.add_argument("blocks", type=int)
    backup = sub.add_parser("backup")
    backup.add_argument("action", choices=("export", "status", "acknowledge"))
    backup.add_argument("--node")
    return p


def main(argv: list[str] | None = None) -> int:
    # Permit --json before or after a subcommand, as promised by the operator API.
    raw_args = list(sys.argv[1:] if argv is None else argv)
    json_requested = "--json" in raw_args
    raw_args = [arg for arg in raw_args if arg != "--json"]
    args = parser().parse_args(raw_args)
    args.json = json_requested
    journal = Journal()
    try:
        if args.command == "status":
            emit(public_status(journal.status()), args.json)
        elif args.command == "node":
            if args.node_command == "register":
                emit(journal.upsert_node(args.name, args.address, args.serial, args.mac, args.ssh_fingerprint), args.json)
                return 0
            nodes = journal.status()["nodes"]
            if args.node_command == "list":
                emit(nodes, args.json)
            else:
                node = next((n for n in nodes if n["name"] == args.node), None)
                if not node:
                    raise StateError(f"unknown node {args.node}")
                emit({"node": args.node, "address": node["mesh_ip"]}, args.json)
        elif args.command == "channel" and args.channel_command == "open":
            record, created = journal.create_open(args.node_from, args.node_to, args.amount_sat, args.network, args.stage_only)
            record["created"] = created
            wake_worker()
            emit(public_operation(record), args.json)
        elif args.command == "channel" and args.channel_command == "publish":
            op = journal.get(args.operation_id)
            if op["state"] != "SIGNED_STAGED":
                raise StateError("only SIGNED_STAGED openings may be queued for publication")
            record = journal.transition(args.operation_id, "PUBLISHING", "operator requested publication")
            wake_worker()
            emit(public_operation(record), args.json)
        elif args.command == "channel" and args.channel_command == "force-close":
            if args.channel_id != args.confirm:
                raise StateError("--confirm must exactly match CHANNEL_ID")
            record, created = journal.create_request("force-close", args.network, {"channel_id": args.channel_id})
            record["created"] = created
            wake_worker()
            emit(public_operation(record), args.json)
        elif args.command == "channel" and args.channel_command == "close":
            record, created = journal.create_request("close", args.network, {"channel_id": args.channel_id})
            record["created"] = created
            wake_worker()
            emit(public_operation(record), args.json)
        elif args.command == "bootstrap":
            if not 1 <= args.expect <= 7:
                raise StateError("--expect must be between 1 and 7")
            record, created = journal.create_request("bootstrap", args.network, {"expect": args.expect})
            if record["state"] != "COMPLETED" and os.environ.get("LN_MESH_ROLE") == "gateway":
                try:
                    subprocess.run(
                        ["/usr/local/lib/lnmesh/gateway-bootstrap.sh", "--expect", str(args.expect)],
                        check=True,
                    )
                except subprocess.CalledProcessError as error:
                    raise StateError(f"bootstrap helper failed with exit status {error.returncode}") from error
                record = journal.finish_request(record["id"], "gateway enrollment completed")
            record["created"] = created
            emit(public_operation(record), args.json)
        elif args.command == "outage":
            record, created = journal.create_request("outage", args.network, {"action": args.action})
            if record["state"] != "COMPLETED" and is_gateway():
                marker = Path(os.environ.get("LN_MESH_STATE_DIR", "/var/lib/lnmesh")) / "manual-outage"
                if args.action == "start":
                    marker.write_text(record["id"] + "\n")
                    os.chmod(marker, 0o600)
                    bitcoin_cli("setnetworkactive", "false")
                else:
                    marker.unlink(missing_ok=True)
                    subprocess.run(["/usr/local/lib/lnmesh/retention-guard.sh"], check=True)
                record = journal.finish_request(record["id"], f"manual outage {args.action} applied")
            record["created"] = created
            emit(public_operation(record), args.json)
        elif args.command == "regtest":
            if args.network != "regtest":
                raise StateError("regtest mine is available only with --network regtest")
            if args.blocks <= 0:
                raise StateError("block count must be positive")
            record, created = journal.create_request("regtest-mine", args.network, {"blocks": args.blocks})
            if record["state"] != "COMPLETED" and is_gateway():
                address = bitcoin_cli("-rpcwallet=lnmesh-miner", "getnewaddress")
                bitcoin_cli("-rpcwallet=lnmesh-miner", "generatetoaddress", str(args.blocks), address)
                record = journal.finish_request(record["id"], f"mined {args.blocks} regtest blocks")
            record["created"] = created
            emit(public_operation(record), args.json)
        elif args.command == "backup":
            record, created = journal.create_request("backup", args.network, {"action": args.action, "node": args.node})
            record["created"] = created
            emit(public_operation(record), args.json)
        elif args.command == "reconcile":
            emit({"pending_operation_ids": [op["id"] for op in journal.list_operations() if op["state"] not in {"ACTIVE", "ABORTED", "CONFLICTED", "FAILED", "CLOSED", "COMPLETED"}]}, args.json)
        else:
            raise StateError("unsupported command")
    except (StateError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            detail = (error.stderr or "external command failed").strip()
            error = StateError(detail[:500])
        if args.json:
            print(json.dumps({"error": str(error)}))
        else:
            print(f"lnmeshctl: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
