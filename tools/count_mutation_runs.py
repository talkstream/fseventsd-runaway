#!/usr/bin/env python3
"""Count mutation-testing runs per day (GMT+7) in local Claude Code transcripts.

A run is a unique Bash tool call whose command contains `stryker run` or `mutmut run`,
excluding --help / --dryRunOnly and lines where the phrase is only searched or printed
(grep, rg, echo, cat). Usage: python3 count_mutation_runs.py
"""
import collections, datetime, glob, json, os, re
TZ = datetime.timezone(datetime.timedelta(hours=7))
RUN = re.compile(r"\b(stryker|mutmut)\s+run\b")
SKIP = re.compile(r"--help|--dryRunOnly|^\s*(grep|rg|echo|cat|printf)\b")
seen, per_day = set(), collections.Counter()
for f in glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True):
    try:
        fh = open(f, errors="replace")
    except OSError:
        continue
    with fh:
        for line in fh:
            if "stryker" not in line and "mutmut" not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            ts, content = d.get("timestamp"), (d.get("message") or {}).get("content")
            if not ts or not isinstance(content, list):
                continue
            day = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(TZ).strftime("%m-%d")
            for c in content:
                if not (isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Bash"):
                    continue
                if c.get("id") in seen:
                    continue
                cmd = (c.get("input") or {}).get("command", "")
                hits = [l for l in cmd.splitlines() if RUN.search(l) and not SKIP.search(l)]
                if hits:
                    seen.add(c.get("id")); per_day[day] += 1
for d in sorted(per_day):
    print(d, per_day[d])
