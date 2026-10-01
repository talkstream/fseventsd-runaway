#!/bin/bash
# fseventsd-check.sh - detect a runaway fseventsd on macOS. No sudo needed.
# Usage: fseventsd-check.sh [--json] [--fast]
#   --json  machine-readable output (unknown numbers are null)
#   --fast  skip the 5 s CPU sample; judge by memory only (cpu_pct is null)
# Exit codes: 0 = OK, 1 = WARN, 2 = RUNAWAY, 3 = cannot measure.
set -u

# ---- thresholds (edit here) -------------------------------------------------
RUNAWAY_MEM_BYTES=1073741824   # 1 GB
RUNAWAY_CPU_PCT=50             # percent of one core, averaged over SAMPLE_SECS
WARN_MEM_BYTES=209715200       # 200 MB
WARN_CPU_PCT=20
SAMPLE_SECS=5
CMD_TIMEOUT=15                 # seconds for every external call
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

# verdict <mem_bytes> <cpu_pct>: print OK/WARN/RUNAWAY, return 0/1/2.
verdict() {
  local mem=$1 cpu=$2 v
  v=$(awk -v m="$mem" -v c="$cpu" \
    -v limm="$RUNAWAY_MEM_BYTES" -v limc="$RUNAWAY_CPU_PCT" \
    -v wm="$WARN_MEM_BYTES" -v wc="$WARN_CPU_PCT" \
    'BEGIN { if (m > limm || c > limc) print 2; else if (m > wm || c > wc) print 1; else print 0 }')
  case $v in
    2) echo RUNAWAY ;;
    1) echo WARN ;;
    *) echo OK ;;
  esac
  return "$v"
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

# parse_budget: read `launchctl print` text on stdin, print the active soft
# jetsam limit in bytes; print nothing (rc 1) if the line is absent.
parse_budget() {
  local line val
  line=$(grep -m1 'jetsam memory limit (active, soft)') || return 1
  val=${line#*= }
  [ -n "$val" ] || return 1
  size_to_bytes "$val"
}

# cpu_to_secs <[dd-][hh:]mm:ss[.ff]>: BSD ps cputime/etime -> seconds.
cpu_to_secs() {
  printf '%s\n' "$1" | awk '{
    s = $1; d = 0
    if (index(s, "-")) { split(s, a, "-"); d = a[1]; s = a[2] }
    n = split(s, p, ":"); t = 0
    for (i = 1; i <= n; i++) t = t * 60 + p[i]
    printf "%.2f\n", t + d * 86400
  }'
}

human_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.1f GB", b / 1073741824
    else if (b >= 1048576) printf "%.1f MB", b / 1048576
    else printf "%.0f KB", b / 1024
  }'
}

# ratio_of <mem> <budget>: print mem/budget with one decimal; nothing unless budget > 0.
ratio_of() {
  case ${2:-} in ''|*[!0-9]*|0) return 0 ;; esac
  awk -v m="$1" -v b="$2" 'BEGIN { printf "%.1f", m / b }'
}

# json_num <value>: print the value if it is a plain number, else null.
json_num() {
  case ${1:-} in
    ''|*[!0-9.]*|.*|*.|*.*.*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

# render_json <verdict> <pid> <uptime> <cpu> <mem> <compressed> <ports> <budget> <swap>
# Print one JSON object. Empty or non-numeric numbers become null.
render_json() {
  local ratio
  ratio=$(ratio_of "$5" "$8")
  printf '{"verdict":"%s","pid":%s,"uptime":"%s","cpu_pct":%s,"mem_bytes":%s,"compressed":"%s","ports":"%s",' \
    "$1" "$(json_num "$2")" "$3" "$(json_num "$4")" "$(json_num "$5")" "$6" "$7"
  if [ -n "$ratio" ]; then
    printf '"budget_bytes":%s,"over_budget_x":%s,' "$(json_num "$8")" "$ratio"
  else
    printf '"budget_bytes":null,"over_budget_x":null,'
  fi
  printf '"swap":"%s"}\n' "$9"
}

main() {
  local json=0 fast=0 pid etime t1 t2 cpu mem mem_h top_line cmprs ports budget
  local budget_txt swap ratio v rc arg
  for arg in "$@"; do
    case $arg in
      --json) json=1 ;;
      --fast) fast=1 ;;
      *) echo "usage: $0 [--json] [--fast]" >&2; exit 64 ;;
    esac
  done

  pid=$(pgrep -x fseventsd | head -n 1)
  if [ -z "$pid" ]; then
    echo "fseventsd is not running" >&2
    exit 3
  fi

  etime=$(ps -o etime= -p "$pid" | tr -d ' ')
  cpu=""
  if [ "$fast" -eq 0 ]; then
    t1=$(cpu_to_secs "$(ps -o time= -p "$pid" | tr -d ' ')")
    sleep "$SAMPLE_SECS"
    t2=$(cpu_to_secs "$(ps -o time= -p "$pid" | tr -d ' ')")
    cpu=$(awk -v a="$t1" -v b="$t2" -v s="$SAMPLE_SECS" 'BEGIN { printf "%.1f", (b - a) / s * 100 }')
  fi

  # Memory: use top's MEM/CMPRS (footprint-like, includes compressed pages).
  # `ps -o rss` only counts resident pages and misses what the VM compressor
  # holds, so a 24 GB daemon can show a tiny RSS. Do not trust rss here.
  top_line=$(run_to "$CMD_TIMEOUT" top -l 1 -pid "$pid" -stats pid,mem,cmprs,ports 2>/dev/null | awk -v p="$pid" '$1 == p { print; exit }')
  mem_h=$(echo "$top_line" | awk '{ print $2 }')
  cmprs=$(echo "$top_line" | awk '{ print $3 }')
  ports=$(echo "$top_line" | awk '{ print $4 }')
  if [ -z "$mem_h" ]; then
    echo "could not read memory from top" >&2
    exit 3
  fi
  mem=$(size_to_bytes "$mem_h")

  budget=$(run_to "$CMD_TIMEOUT" launchctl print system/com.apple.fseventsd 2>/dev/null | parse_budget)
  swap=$(sysctl -n vm.swapusage 2>/dev/null)

  ratio=$(ratio_of "$mem" "$budget")
  budget_txt="not found in launchctl print"
  if [ -n "$ratio" ]; then budget_txt=$(human_bytes "$budget"); fi

  v=$(verdict "$mem" "${cpu:-0}")
  rc=$?

  if [ "$json" -eq 1 ]; then
    render_json "$v" "$pid" "$etime" "$cpu" "$mem" "$cmprs" "$ports" "$budget" "$swap"
  else
    echo "fseventsd PID:      $pid (uptime $etime)"
    if [ "$fast" -eq 1 ]; then
      echo "CPU:                skipped (--fast)"
    else
      echo "CPU (${SAMPLE_SECS}s avg):    ${cpu} %"
    fi
    echo "Memory footprint:   $(human_bytes "$mem") (compressed: $cmprs, mach ports: $ports)"
    echo "Apple budget:       $budget_txt"
    if [ -n "$ratio" ]; then echo "Over budget:        ${ratio}x"; fi
    echo "Swap:               $swap"
    echo "Verdict:            $v"
    if [ "$rc" -eq 2 ]; then
      echo
      echo "Runaway fseventsd. Suggested next steps:"
      echo "  curl -fsSLO https://raw.githubusercontent.com/talkstream/fseventsd-runaway/main/fseventsd-restart.sh"
      echo "  sudo bash fseventsd-restart.sh                 # saves evidence first, then restarts the daemon"
      echo "  sudo bash fseventsd-restart.sh --no-evidence   # restart only"
    fi
  fi
  exit "$rc"
}

# Run main unless sourced for testing (selftest sets FSEVENTSD_CHECK_NO_MAIN=1).
if [ "${FSEVENTSD_CHECK_NO_MAIN:-0}" != "1" ]; then
  main "$@"
fi
