"""Leaf-side, one-shot enrollment handler invoked by a forced SSH command."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


class EnrollmentError(RuntimeError):
    pass


def atomic_write(path: Path, content: str, mode: int, uid: int = 0, gid: int = 0) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.chown(temporary, uid, gid)
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def public_key(value: object, label: str) -> str:
    if not isinstance(value, str) or "\n" in value or not value.startswith("ssh-ed25519 "):
        raise EnrollmentError(f"invalid {label}")
    return value.strip()


def validate(data: object) -> dict[str, object]:
    if not isinstance(data, dict):
        raise EnrollmentError("payload must be an object")
    name = data.get("name")
    address = data.get("address")
    network = data.get("network")
    rpc_port = data.get("rpc_port")
    rpc_user = data.get("rpc_user")
    rpc_password = data.get("rpc_password")
    if not isinstance(name, str) or not re.fullmatch(r"n0[1-7]", name):
        raise EnrollmentError("invalid node name")
    expected_octet = int(name[-1]) + 1
    if address != f"10.77.0.{expected_octet}":
        raise EnrollmentError("node address does not match its assigned name")
    if network not in {"regtest", "testnet4", "bitcoin"}:
        raise EnrollmentError("invalid network")
    installed_network = Path("/var/lib/lnmesh/network").read_text().strip()
    if network != installed_network:
        raise EnrollmentError("gateway and leaf networks differ")
    if not isinstance(rpc_port, int) or not 1 <= rpc_port <= 65535:
        raise EnrollmentError("invalid RPC port")
    if not isinstance(rpc_user, str) or not re.fullmatch(r"lnmesh_n0[1-7]", rpc_user):
        raise EnrollmentError("invalid RPC user")
    if not isinstance(rpc_password, str) or not re.fullmatch(r"[0-9a-f]{64}", rpc_password):
        raise EnrollmentError("invalid RPC credential")
    data["control_public_key"] = public_key(data.get("control_public_key"), "control public key")
    data["tunnel_public_key"] = public_key(data.get("tunnel_public_key"), "tunnel public key")
    return data


def remove_bootstrap_keys(authorized_keys: Path) -> None:
    if not authorized_keys.exists():
        return
    retained = [line for line in authorized_keys.read_text().splitlines() if " lnmesh-bootstrap-" not in line]
    atomic_write(authorized_keys, "\n".join(retained) + ("\n" if retained else ""), 0o600)


def main() -> int:
    try:
        raw = os.read(0, 32_769)
        if len(raw) > 32_768:
            raise EnrollmentError("payload too large")
        data = validate(json.loads(raw))
        marker = Path("/var/lib/lnmesh/enrolled")
        public_record = {key: data[key] for key in ("name", "address", "network", "rpc_port", "rpc_user")}
        if marker.exists():
            if json.loads(marker.read_text()) != public_record:
                raise EnrollmentError("leaf is already enrolled with different settings")
            print("already-enrolled")
            return 0

        import pwd
        lightning = pwd.getpwnam("lightning")
        tunnel = pwd.getpwnam("lnmesh-tunnel")
        conf = [
            f"network={data['network']}",
            f"alias={data['name']}",
            f"bind-addr={data['address']}:9735",
            f"bitcoin-rpcconnect=127.0.0.1",
            f"bitcoin-rpcport={data['rpc_port']}",
            f"bitcoin-rpcuser={data['rpc_user']}",
            f"bitcoin-rpcpassword={data['rpc_password']}",
            "log-level=info",
        ]
        conf.append("funding-confirms=3" if data["network"] == "bitcoin" else "funding-confirms=1")
        if data["network"] == "bitcoin":
            conf.append("watchtime-blocks=1008")
        elif data["network"] == "regtest":
            conf.append("watchtime-blocks=6")
        atomic_write(Path("/etc/lnmesh/lightning.conf"), "\n".join(conf) + "\n", 0o640, 0, lightning.pw_gid)

        ibss = Path("/etc/lnmesh/ibss.env")
        lines = [line for line in ibss.read_text().splitlines() if not line.startswith("LN_MESH_NODE_ADDRESS=")]
        lines.append(f"LN_MESH_NODE_ADDRESS={data['address']}/24")
        atomic_write(ibss, "\n".join(lines) + "\n", 0o644)

        root_keys = Path("/root/.ssh/authorized_keys")
        remove_bootstrap_keys(root_keys)
        with root_keys.open("a", encoding="utf-8") as handle:
            handle.write(f'restrict,command="/usr/local/lib/lnmesh/leaf-control-shell.sh" {data["control_public_key"]}\n')
            handle.flush()
            os.fsync(handle.fileno())
        tunnel_key = f'restrict,port-forwarding,permitlisten="127.0.0.1:{data["rpc_port"]}" {data["tunnel_public_key"]}\n'
        atomic_write(Path("/var/lib/lnmesh-tunnel/.ssh/authorized_keys"), tunnel_key, 0o600, tunnel.pw_uid, tunnel.pw_gid)
        atomic_write(marker, json.dumps(public_record, sort_keys=True) + "\n", 0o600)
        subprocess.run(["/usr/bin/hostnamectl", "set-hostname", str(data["name"])], check=True)
        subprocess.run([
            "/usr/bin/systemd-run", "--quiet", "--unit=lnmesh-finish-enrollment",
            "--on-active=3s", "/usr/local/lib/lnmesh/finish-enrollment.sh"
        ], check=True)
        print("enrolled")
        return 0
    except (EnrollmentError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"enrollment refused: {error}", file=os.sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
