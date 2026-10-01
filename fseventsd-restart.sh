#!/bin/bash
# fseventsd-restart.sh - collect evidence, then restart fseventsd without a reboot. Needs sudo.
# Usage: sudo ./fseventsd-restart.sh [--no-evidence]
# Restarting wipes fseventsd's event history, so evidence is saved FIRST.
# `launchctl kickstart` is not used: SIP refuses it for this service.
set -u

CMD_TIMEOUT=20      # seconds for every external call
TERM_WAIT_SECS=10   # how long to wait for a respawn after SIGTERM
WAIT_SECS=30        # how long to wait after SIGKILL (launchd throttles respawns)
FSEVENTS_DIR=/System/Volumes/Data/.fseventsd

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

get_pid() { pgrep -x fseventsd | head -n 1; }

# is_fseventsd <pid>: true if the PID still belongs to fseventsd (guards against PID reuse).
is_fseventsd() {
  local c
  c=$(ps -o comm= -p "$1" 2>/dev/null)
  case $c in
    fseventsd|*/fseventsd) return 0 ;;
    *) return 1 ;;
  esac
}

# send_sig <signal> <pid>: signal the old daemon only if it is still fseventsd.
send_sig() {
  if is_fseventsd "$2"; then
    echo "Sending SIG$1 to $2 ..."
    kill -"$1" "$2" 2>/dev/null
  else
    echo "old process gone; waiting for launchd"
  fi
}

# wait_new <old_pid> <secs>: print the new fseventsd PID once it differs from old_pid.
wait_new() {
  local i=0 n
  while [ "$i" -lt "$2" ]; do
    sleep 1
    n=$(get_pid)
    if [ -n "$n" ] && [ "$n" != "$1" ]; then printf '%s\n' "$n"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# evidence_base: print the directory that will hold the evidence dir: the home of
# $SUDO_USER (name validated, home read from the directory service, no eval), else /var/tmp.
evidence_base() {
  local home=""
  if printf '%s\n' "${SUDO_USER:-}" | grep -Eq '^[a-z_][a-z0-9_-]*$'; then
    home=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  fi
  if [ -n "$home" ] && [ -d "$home" ] && [ ! -L "$home" ]; then
    printf '%s\n' "$home"
  else
    printf '%s\n' /var/tmp
  fi
}

describe() {
  local pid=$1
  echo "  PID $pid, uptime $(ps -o etime= -p "$pid" | tr -d ' ')"
  run_to "$CMD_TIMEOUT" top -l 1 -pid "$pid" -stats pid,mem,cmprs,ports 2>/dev/null | awk -v p="$pid" '$1 == p { print "  mem " $2 ", compressed " $3 ", ports " $4 }'
}

# files_per_day: reads `ls -laT` output on stdin, prints "YYYY Mon DD count" per day for regular files.
# ls -T prints "Mon DD hh:mm:ss YYYY" or "DD Mon hh:mm:ss YYYY" depending on locale; accept both.
files_per_day() {
  awk '/^-/ && NF >= 10 {
    if ($6 ~ /^[0-9]+$/) { d = $6; m = $7 } else { m = $6; d = $7 }
    n[$9 " " m " " sprintf("%02d", d)]++
  } END { for (k in n) print k, n[k] }' | sort
}

# evidence_ok <dir>: true if the saved .fseventsd listing holds at least one log file,
# i.e. a line ending in a 16-digit hex event ID (an error message does not count).
evidence_ok() {
  grep -Eq '^-.* [0-9a-f]{16}$' "$1/fseventsd-dir.txt" 2>/dev/null
}

collect_evidence() {
  local pid=$1 dir base
  umask 077
  base=$(evidence_base)
  dir=$(mktemp -d "$base/fseventsd-evidence-$(date +%Y%m%d-%H%M%S).XXXXXX") \
    || { echo "cannot create an evidence directory in $base" >&2; return 1; }
  echo "Saving evidence to $dir ..."
  run_to "$CMD_TIMEOUT" top -l 1 -pid "$pid" -stats pid,mem,cmprs,ports >"$dir/top.txt" 2>&1
  run_to "$CMD_TIMEOUT" footprint "$pid" >"$dir/footprint.txt" 2>&1
  run_to 120 ls -laT "$FSEVENTS_DIR" >"$dir/fseventsd-dir.txt" 2>&1
  files_per_day <"$dir/fseventsd-dir.txt" >"$dir/fseventsd-files-per-day.txt"
  run_to 30 sample "$pid" 5 -file "$dir/sample.txt" >/dev/null 2>&1
  run_to "$CMD_TIMEOUT" lsmp -p "$pid" >"$dir/lsmp.txt" 2>&1
  run_to "$CMD_TIMEOUT" launchctl print system/com.apple.fseventsd >"$dir/launchctl-print.txt" 2>&1
  run_to "$CMD_TIMEOUT" sysctl vm.swapusage >"$dir/swap.txt" 2>&1
  # The history listing is what a restart destroys: without it, refuse.
  if ! evidence_ok "$dir"; then
    echo "the event-history listing was not saved in $dir" >&2
    return 1
  fi
  [ -s "$dir/sample.txt" ] || echo "warning: sample(1) output missing; continuing" >&2
  # Hand the directory back to the invoking user.
  if printf '%s\n' "${SUDO_USER:-}" | grep -Eq '^[a-z_][a-z0-9_-]*$'; then
    chown -R "$SUDO_USER" "$dir" 2>/dev/null
  fi
  echo "Evidence saved: $dir"
}

main() {
  local evidence=1 old new
  case "${1:-}" in
    --no-evidence) evidence=0 ;;
    "") ;;
    *) echo "usage: sudo $0 [--no-evidence]" >&2; exit 64 ;;
  esac

  if [ "$(id -u)" -ne 0 ]; then
    echo "error: this script must run as root. Try: sudo $0 ${1:-}" >&2
    exit 77
  fi

  old=$(get_pid)
  if [ -z "$old" ]; then
    echo "fseventsd is not running (launchd should start it); nothing to restart." >&2
    exit 1
  fi

  echo "Before:"
  describe "$old"

  if [ "$evidence" -eq 1 ]; then
    if ! collect_evidence "$old"; then
      echo "evidence failed; not restarting (use --no-evidence to force)" >&2
      exit 1
    fi
  else
    echo "Skipping evidence (--no-evidence)."
  fi

  send_sig TERM "$old"
  new=$(wait_new "$old" "$TERM_WAIT_SECS")

  if [ -z "$new" ]; then
    echo "No new PID after ${TERM_WAIT_SECS}s."
    send_sig KILL "$old"
    new=$(wait_new "$old" "$WAIT_SECS")
  fi

  if [ -z "$new" ]; then
    echo "error: fseventsd did not come back; check 'launchctl print system/com.apple.fseventsd'" >&2
    exit 1
  fi

  echo "After:"
  describe "$new"
}

# Run main unless sourced for testing (selftest sets FSEVENTSD_RESTART_NO_MAIN=1).
if [ "${FSEVENTSD_RESTART_NO_MAIN:-0}" != "1" ]; then
  main "$@"
fi
