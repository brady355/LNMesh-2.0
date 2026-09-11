"""Restricted Core Lightning JSON-RPC bridge for a leaf forced SSH command."""

from __future__ import annotations

import json
import os
import socket
import sys
from pathlib import Path

ALLOWED_METHODS = {
    "close",
    "connect",
    "fundchannel_complete",
    "fundchannel_start",
    "getinfo",
    "listfunds",
    "listpeerchannels",
    "listpeers",
    "listtransactions",
    "newaddr",
    "sendpsbt",
    "signpsbt",
    "txdiscard",
    "txprepare",
}


def rpc_socket() -> Path:
    network = Path("/var/lib/lnmesh/network").read_text().strip()
    candidates = (
        Path("/var/lib/lightning") / network / "lightning-rpc",
        Path("/var/lib/lightning/lightning-rpc"),
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise RuntimeError("lightning-rpc socket is unavailable")


def main() -> int:
    raw = os.read(0, 1_048_577)
    if len(raw) > 1_048_576:
        raise RuntimeError("RPC request is too large")
    request = json.loads(raw)
    if not isinstance(request, dict) or request.get("method") not in ALLOWED_METHODS:
        raise RuntimeError("RPC method is not permitted")
    params = request.get("params", {})
    if not isinstance(params, (dict, list)):
        raise RuntimeError("RPC params must be an object or array")
    wire = json.dumps({"jsonrpc": "2.0", "id": "lnmesh", "method": request["method"], "params": params}).encode() + b"\n\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(120)
        client.connect(str(rpc_socket()))
        client.sendall(wire)
        buffer = b""
        while len(buffer) <= 16 * 1024 * 1024:
            chunk = client.recv(65_536)
            if not chunk:
                break
            buffer += chunk
            try:
                response = json.loads(buffer)
                break
            except json.JSONDecodeError:
                continue
        else:
            raise RuntimeError("RPC response is too large")
    if "response" not in locals():
        raise RuntimeError("incomplete RPC response")
    if response.get("error") is not None:
        print(json.dumps({"error": response["error"]}, separators=(",", ":")))
        return 1
    print(json.dumps(response.get("result"), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({"error": {"message": str(error)}}), file=sys.stderr)
        raise SystemExit(1)
