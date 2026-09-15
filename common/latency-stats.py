#!/usr/bin/env python3
"""Summarises the payment latencies in the transcript of a latency run.

The three arms print one line per payment in the same shape, for example
  A 12 OK paid 0.001 XRP total 0.012 XRP version 12 in 44 ms (sign 6.4 ms)
  C 3 +9s OK paid 1 ADA mine 95 ADA snapshot 7 in 210 ms (sign 0.7 ms, http 20 ms)
  A 5 OK 8ms version=5
The script prints one table row per series with the count, the errors and the
minimum, median, mean, 95th percentile and maximum latency in milliseconds.
Usage: latency-stats.py run-05.txt
"""
import re
import statistics
import sys

pat = re.compile(r"^([A-Z]) (\d+) (?:\+\d+s )?(OK|ERR)\b(.*)$")
ms_pat = re.compile(r"(?: in (\d+) ms\b)|(?:^ (\d+)ms\b)")
series = {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = pat.match(line.strip())
    if not m:
        continue
    s = series.setdefault(m.group(1), {"n": 0, "err": 0, "ms": []})
    s["n"] += 1
    if m.group(3) == "ERR":
        s["err"] += 1
        continue
    t = ms_pat.search(m.group(4))
    if t:
        s["ms"].append(int(t.group(1) or t.group(2)))


def p95(v):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(0.95 * len(v) + 0.5)) - 1)]


print("| Series | n | errors | min | median | mean | p95 | max (ms) |")
print("|---|---|---|---|---|---|---|---|")
for k in sorted(series):
    s = series[k]
    if s["ms"]:
        print(f"| {k} | {s['n']} | {s['err']} | {min(s['ms'])} | {statistics.median(s['ms']):.0f} | "
              f"{statistics.mean(s['ms']):.1f} | {p95(s['ms'])} | {max(s['ms'])} |")
    else:
        print(f"| {k} | {s['n']} | {s['err']} | - | - | - | - | - |")
