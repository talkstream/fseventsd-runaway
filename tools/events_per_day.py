#!/usr/bin/env python3
"""Events per day from an `ls -laT /System/Volumes/Data/.fseventsd` listing.

Each log file is named by a hex FSEvents event ID that grows monotonically, so the
difference between the last IDs of consecutive days approximates events per day.
Caveats: right after a boot the ID can jump by billions without events (drop that
day); the last day is usually partial, so its per-second average is too low.
Usage: python3 events_per_day.py fseventsd-dir.txt
"""
import collections, datetime, re, sys
MON = {m: i for i, m in enumerate("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), 1)}
rows = []
for line in open(sys.argv[1]):
    f = line.split()
    if not line.startswith("-") or len(f) < 10 or not re.fullmatch(r"[0-9a-f]{16}", f[-1]):
        continue
    d, m = (int(f[5]), MON[f[6]]) if f[5].isdigit() else (int(f[6]), MON[f[5]])
    hh, mm, ss = map(int, f[7].split(":"))
    rows.append((datetime.datetime(int(f[8]), m, d, hh, mm, ss), int(f[-1], 16)))
rows.sort()
last = collections.OrderedDict()
count = collections.Counter()
for t, i in rows:
    k = t.strftime("%Y-%m-%d"); last[k] = max(last.get(k, 0), i); count[k] += 1
prev = None
print("day files events avg_per_s")
for k, v in last.items():
    ev = v - prev if prev is not None else 0
    prev = v
    print(k, count[k], ev, round(ev / 86400))
