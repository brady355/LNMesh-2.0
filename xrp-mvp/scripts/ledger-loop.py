#!/usr/bin/env python3
"""Runs on the gateway. Advances the stand-alone xrpld ledger every INTERVAL
seconds with the admin-only ledger_accept command. The default interval of 4 s
follows the public XRP Ledger. The script needs only the standard library.

Usage: ledger-loop.py [http://127.0.0.1:5005] [4]
"""
import json
import sys
import time
import urllib.request

url = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:5005"
interval = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
body = json.dumps({"method": "ledger_accept", "params": [{}]}).encode()
next_t = time.monotonic()
while True:
    next_t += interval
    try:
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=4) as r:
            res = json.load(r)["result"]
            print(time.strftime("%H:%M:%S", time.gmtime()), "ledger", res.get("ledger_current_index"), flush=True)
    except Exception as e:  # noqa: BLE001
        print(time.strftime("%H:%M:%S", time.gmtime()), "ledger_accept failed:", e, flush=True)
    time.sleep(max(0.0, next_t - time.monotonic()))
