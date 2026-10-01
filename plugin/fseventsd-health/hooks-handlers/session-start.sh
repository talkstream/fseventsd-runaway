#!/bin/bash
# fseventsd-health SessionStart hook (macOS only, read-only, no sudo).
# Prints nothing when fseventsd is healthy. Never fails the session: always exit 0.
# Test overrides (only honoured when FSEVENTSD_HEALTH_TEST=1):
#   FSEVENTSD_HEALTH_FAKE_UNAME, FSEVENTSD_HEALTH_FAKE_MEM_BYTES,
#   FSEVENTSD_HEALTH_FAKE_BUDGET_BYTES ("none" = budget line absent).

# ---- thresholds (edit here) -------------------------------------------------
WARN_MEM_BYTES=209715200       # 200 MB
RUNAWAY_MEM_BYTES=1073741824   # 1 GB
DEFAULT_BUDGET_BYTES=31457280  # 30 MB, used when launchctl shows no limit
CMD_TIMEOUT=2                  # seconds for every external call
# -----------------------------------------------------------------------------

# run_to <secs> <cmd...>: run a command with a timeout (macOS has no timeout(1)).
run_to() {
  local secs=$1 pid watcher rc
  shift
  "$@" &
  pid=$!
  ( sleep "$secs" && kill -KILL "$pid" ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" 2>/dev/null
  rc=$?
  # Freeze the watcher, kill its sleep child (so the && branch is skipped),
  # then the watcher itself: nothing is left reparented to launchd.
  kill -STOP "$watcher" 2>/dev/null
  pkill -P "$watcher" 2>/dev/null
  kill -KILL "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return "$rc"
}

# size_to_bytes <n[unit]>: "3648K", "24G", "1.5M+", "30 MB" -> integer bytes.
size_to_bytes() {
  printf '%s\n' "$1" | tr -d '+-' | awk '{
    s = toupper($0); gsub(/[ B]/, "", s)
    u = substr(s, length(s), 1); n = s
    if (u ~ /[KMGT]/) n = substr(s, 1, length(s) - 1)
    mult = 1
    if (u == "K") mult = 1024
    if (u == "M") mult = 1048576
    if (u == "G") mult = 1073741824
    if (u == "T") mult = 1099511627776
    printf "%.0f\n", n * mult
  }'
}

human_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.1f GB", b / 1073741824
    else if (b >= 1048576) printf "%.1f MB", b / 1048576
    else printf "%.0f KB", b / 1024
  }'
}

# measure_mem: print fseventsd memory footprint in bytes (nothing on failure).
measure_mem() {
  local pid line mem_h
  pid=$(run_to "$CMD_TIMEOUT" pgrep -x fseventsd | head -n 1)
  [ -n "$pid" ] || return 1
  line=$(run_to "$CMD_TIMEOUT" top -l 1 -pid "$pid" -stats pid,mem 2>/dev/null | awk -v p="$pid" '$1 == p { print; exit }')
  mem_h=$(printf '%s\n' "$line" | awk '{ print $2 }')
  [ -n "$mem_h" ] || return 1
  size_to_bytes "$mem_h"
}

# measure_budget: print the active soft jetsam limit in bytes (nothing if absent).
measure_budget() {
  local line val
  line=$(run_to "$CMD_TIMEOUT" launchctl print system/com.apple.fseventsd 2>/dev/null | grep -m1 'jetsam memory limit (active, soft)') || return 1
  val=${line#*= }
  [ -n "$val" ] || return 1
  size_to_bytes "$val"
}

main() {
  local os mem budget budget_note="" mem_h budget_h ratio level msg ctx
  os=$(uname)
  if [ "${FSEVENTSD_HEALTH_TEST:-0}" = "1" ] && [ -n "${FSEVENTSD_HEALTH_FAKE_UNAME:-}" ]; then
    os=$FSEVENTSD_HEALTH_FAKE_UNAME
  fi
  [ "$os" = "Darwin" ] || return 0

  if [ "${FSEVENTSD_HEALTH_TEST:-0}" = "1" ] && [ -n "${FSEVENTSD_HEALTH_FAKE_MEM_BYTES:-}" ]; then
    mem=$FSEVENTSD_HEALTH_FAKE_MEM_BYTES
    budget=${FSEVENTSD_HEALTH_FAKE_BUDGET_BYTES:-}
    [ "$budget" = "none" ] && budget=""
  else
    mem=$(measure_mem)
    budget=$(measure_budget)
  fi

  case $mem in ''|*[!0-9]*) return 0 ;; esac
  [ "$mem" -gt "$WARN_MEM_BYTES" ] 2>/dev/null || return 0

  case $budget in ''|*[!0-9]*|0) budget=""  ;; esac
  if [ -z "$budget" ]; then
    budget=$DEFAULT_BUDGET_BYTES
    budget_note=" (default; not found in launchctl print)"
  fi

  level=WARN
  [ "$mem" -gt "$RUNAWAY_MEM_BYTES" ] && level=RUNAWAY
  mem_h=$(human_bytes "$mem")
  budget_h=$(human_bytes "$budget")
  ratio=$(awk -v m="$mem" -v b="$budget" 'BEGIN { printf "%.0f", m / b }')

  msg="fseventsd ${level}: uses ${mem_h}, ${ratio}x its ${budget_h} budget${budget_note}. Fix without reboot: sudo kill -TERM \$(pgrep -x fseventsd) - save evidence first, see https://github.com/talkstream/fseventsd-runaway"
  ctx="The macOS system daemon fseventsd (file-event service) is using ${mem_h}, ${ratio}x its ${budget_h} budget${budget_note}; level ${level}. This slows file watchers and can cause swap and heat. Do not run sudo yourself. Suggest the user run in their own terminal: sudo kill -TERM \$(pgrep -x fseventsd) (launchd restarts the daemon at once; the event history is wiped, so save /System/Volumes/Data/.fseventsd evidence first). Details: https://github.com/talkstream/fseventsd-runaway"

  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg" "$ctx"
}

# Capture output so any failure inside main stays silent and the exit code is always 0.
out=$(main 2>/dev/null </dev/null) || out=""
if [ -n "$out" ]; then printf '%s\n' "$out"; fi
exit 0
