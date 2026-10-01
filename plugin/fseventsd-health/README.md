# fseventsd-health

A Claude Code plugin that checks the macOS system daemon `fseventsd` when a session starts. If the daemon has grown far beyond its memory budget, it warns at every session start while that lasts, and prints the fix. It stays silent while the daemon is healthy.

Background: on heavy agentic workloads `fseventsd` can grow to tens of GB and pin a CPU core. Apple's own budget for it is 30 MB (`launchctl print system/com.apple.fseventsd`, line `jetsam memory limit (active, soft)`), and a soft limit does not kill it. Research and numbers: https://github.com/talkstream/fseventsd-runaway

## What it does

- Reads the memory footprint of `fseventsd` with `top -l 1 -pid <pid> -stats pid,mem` (includes compressed pages, unlike `ps rss`).
- Reads the budget from `launchctl print system/com.apple.fseventsd`; if the line is absent it assumes 30 MB and says so.
- Up to 200 MB: prints nothing. Above 200 MB (WARN) or 1 GB (RUNAWAY): shows you one line with the size, the multiple of the budget, and the command `sudo kill -TERM $(pgrep -x fseventsd)`; also tells the model not to run sudo itself but to suggest the command to you.
- Thresholds are variables at the top of `hooks-handlers/session-start.sh`.

## Install

From the marketplace in this repository:

```
/plugin marketplace add talkstream/fseventsd-runaway
/plugin install fseventsd-health@fseventsd-runaway
```

Or load it from a local checkout for one session:

```
claude --plugin-dir ./plugin/fseventsd-health
```

## What it does NOT do

- Changes nothing on your system and never runs sudo.
- Does not sample CPU (memory only), so it finishes in well under a second; the hook timeout is 10 s and every external call is limited to 2 s.
- Does nothing on non-macOS systems.
- Never breaks session start: any error ends silently with exit code 0.

## Tests

```
bash tests/selftest.sh
SELFTEST_BREAK=1 bash tests/selftest.sh   # must fail
```
