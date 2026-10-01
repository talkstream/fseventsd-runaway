#!/usr/bin/env python3
"""Count unique Claude Code tool calls per day (GMT+7) across all local transcripts.

Walks ~/.claude/projects recursively (sessions and subagents), dedups by tool_use id
(forked sessions copy earlier messages), prints per-day totals and Pearson r against
the fseventsd log-file counts given on the command line as DAY=COUNT pairs.
"""
import datetime, glob, json, os, statistics, sys, collections
TZ = datetime.timezone(datetime.timedelta(hours=7))
seen, per_day = set(), collections.Counter()
files = glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True)
for f in files:
    try:
        fh = open(f, errors="replace")
    except OSError:
        continue
    with fh:
        for line in fh:
            if '"tool_use"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            ts = d.get("timestamp")
            content = (d.get("message") or {}).get("content")
            if not ts or not isinstance(content, list):
                continue
            day = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(TZ).strftime("%m-%d")
            for c in content:
                if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("id") not in seen:
                    seen.add(c.get("id")); per_day[day] += 1
print(f"transcripts={len(files)} unique_tool_calls={len(seen)}")
logs = dict(a.split("=") for a in sys.argv[1:])
days = sorted(logs)
for d in days:
    print(d, per_day[d], logs[d])
if len(days) > 2:
    x = [per_day[d] for d in days]; y = [int(logs[d]) for d in days]
    print("pearson_r=%.3f" % statistics.correlation(x, y))
