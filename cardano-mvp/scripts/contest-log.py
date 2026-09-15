#!/usr/bin/env python3
"""Prints the contest attempts of a hydra-node after a given time, one per line.

hydra-node logs one JSON object per line. The script reads that log, keeps the
lines about a contest transaction and prints when the node posted a contest,
when a post failed and with which validator errors, and when the node observed
a contest on chain. The cheat test runs it on the victim after a stale close,
so the transcript shows why a late contest fails.

Usage: contest-log.py hydra-node.log HH:MM:SS
"""
import re
import sys

path, since = sys.argv[1], sys.argv[2]
for line in open(path, encoding="utf-8", errors="replace"):
    if "contestingSnapshot" not in line and "OnContestTx" not in line:
        continue
    m = re.match(r'\{"timestamp":"[0-9-]+T([0-9:.]{12})', line)
    if not m or m.group(1)[:8] < since:
        continue
    t = m.group(1)
    if '"tag":"ToPost"' in line:
        n = re.search(r'"number":(\d+)', line)
        print(f"{t} posts a contest with snapshot {n.group(1) if n else '?'}")
    elif '"chainEvent"' in line and "failureReason" in line:
        codes = re.findall(r'\\"([A-Z]{1,3}\d{1,3})\\"', line)
        print(f"{t} the contest failed with the validator errors {', '.join(codes) or 'unknown'}")
    elif '"chainEvent"' in line and "OnContestTx" in line:
        n = re.search(r'"snapshotNumber":(\d+)', line)
        print(f"{t} observed a contest on chain with snapshot {n.group(1) if n else '?'}")
