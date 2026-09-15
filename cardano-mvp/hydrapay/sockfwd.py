#!/usr/bin/env python3
"""sockfwd: forwards the node-to-client socket of cardano-node across the mesh.

The leaves have neither socat nor root, so this forwarder from the standard
library does the job. On the gateway it publishes the node socket on a TCP
port for the leaves. On a leaf it creates a local UNIX socket and connects
every client of that socket to the TCP port. Thus hydra-node on the leaf talks
to the cardano-node of the gateway as if the node were local.

  gateway: sockfwd.py tcp2unix 0.0.0.0:3333 ~/lnmesh-ada/devnet/node.socket
  leaf:    sockfwd.py unix2tcp ~/lnmesh-ada/node.socket 10.10.0.1:3333
"""
import asyncio
import os
import sys
import time


def log(*a):
    print(time.strftime("%H:%M:%S", time.gmtime()), *a, flush=True)


async def pump(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError, OSError):
        pass
    finally:
        try:
            writer.close()
        except OSError:
            pass


def handler(open_upstream):
    async def handle(reader, writer):
        try:
            up_r, up_w = await open_upstream()
        except OSError as e:
            log("upstream connect failed:", e)
            writer.close()
            return
        await asyncio.gather(pump(reader, up_w), pump(up_r, writer))
    return handle


async def main():
    mode, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
    if mode == "tcp2unix":
        host, port = a.rsplit(":", 1)
        srv = await asyncio.start_server(handler(lambda: asyncio.open_unix_connection(b)), host, int(port))
        log(f"tcp {a} -> unix {b}")
    elif mode == "unix2tcp":
        host, port = b.rsplit(":", 1)
        if os.path.exists(a):
            os.unlink(a)
        srv = await asyncio.start_unix_server(handler(lambda: asyncio.open_connection(host, int(port))), a)
        log(f"unix {a} -> tcp {b}")
    else:
        sys.exit("usage: sockfwd.py tcp2unix HOST:PORT UNIXPATH | unix2tcp UNIXPATH HOST:PORT")
    async with srv:
        await srv.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
