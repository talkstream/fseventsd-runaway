#!/bin/bash
# selftest.sh - tests verdict logic and the launchctl budget parser without a real fseventsd.
# SELFTEST_BREAK=1 makes one expectation wrong on purpose, to prove the test can fail.
set -u
here=$(cd "$(dirname "$0")" && pwd)
FSEVENTSD_CHECK_NO_MAIN=1
export FSEVENTSD_CHECK_NO_MAIN
# shellcheck source=fseventsd-check.sh
. "$here/fseventsd-check.sh"

fails=0
total=0

# expect <name> <expected> <actual>
expect() {
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1: expected '$2', got '$3'"
    fails=$((fails + 1))
  fi
}

# check_verdict <name> <mem> <cpu> <want_text> <want_rc>
check_verdict() {
  local out rc
  out=$(verdict "$2" "$3")
  rc=$?
  expect "$1 text" "$4" "$out"
  expect "$1 rc" "$5" "$rc"
}

MB=1048576
GB=1073741824

check_verdict "healthy"                 $((10 * MB)) 0.5 OK 0
check_verdict "RUNAWAY by memory (24G)" $((24 * GB)) 1 RUNAWAY 2
check_verdict "RUNAWAY by cpu"          $((10 * MB)) 99 RUNAWAY 2
check_verdict "WARN by memory"          $((300 * MB)) 1 WARN 1
check_verdict "WARN by cpu"             $((10 * MB)) 30 WARN 1
check_verdict "boundary: mem exactly 200MB is OK" $((200 * MB)) 20 OK 0
check_verdict "boundary: 200MB+1 is WARN" $((200 * MB + 1)) 0 WARN 1
check_verdict "boundary: mem exactly 1GB is WARN" "$GB" 0 WARN 1
check_verdict "boundary: cpu 50 is WARN" 0 50 WARN 1
check_verdict "boundary: cpu 50.1 is RUNAWAY" 0 50.1 RUNAWAY 2

# Budget parser on a fixture (tab-indented like real launchctl output).
fixture=$(printf 'foo = bar\n\tjetsam priority = 180\n\tjetsam memory limit (active, soft) = 30 MB\n\tjetsam memory limit (inactive, soft) = 20 MB\n')
expect "budget parse" "31457280" "$(printf '%s\n' "$fixture" | parse_budget)"
printf '%s\n' "no limit here" | parse_budget >/dev/null
expect "budget missing -> rc 1" "1" "$?"

expect "size 24G" "25769803776" "$(size_to_bytes 24G)"
expect "size 3648K" "3735552" "$(size_to_bytes 3648K)"
expect "cputime 56:57.12" "3417.12" "$(cpu_to_secs 56:57.12)"
expect "cputime 1-02:03:04" "93784.00" "$(cpu_to_secs 1-02:03:04)"

# Per-day summary of /.fseventsd listings: both column orders that ls -T uses.
FSEVENTSD_RESTART_NO_MAIN=1
export FSEVENTSD_RESTART_NO_MAIN
# shellcheck source=fseventsd-restart.sh
. "$here/fseventsd-restart.sh"
listing_dm=$(printf '%s\n' \
  'drwx------  65535 root  wheel  2991872  1 Oct 23:20:09 2026 .' \
  '-rw-------      1 root  wheel    39566 30 Aug 21:15:12 2026 00000000000040eb' \
  '-rw-------      1 root  wheel    50700 30 Aug 21:15:14 2026 0000000000008b03' \
  '-rw-------      1 root  wheel    41321  1 Oct 21:15:30 2026 000000000000d8f2')
listing_md=$(printf '%s\n' \
  '-rw-------  1 root  wheel  39566 Aug 30 21:15:12 2026 00000000000040eb' \
  '-rw-------  1 root  wheel  41321 Oct  1 21:15:30 2026 000000000000d8f2')
expect "files/day, day-month order" "2026 Aug 30 2|2026 Oct 01 1" \
  "$(printf '%s\n' "$listing_dm" | files_per_day | paste -sd '|' -)"
expect "files/day, month-day order" "2026 Aug 30 1|2026 Oct 01 1" \
  "$(printf '%s\n' "$listing_md" | files_per_day | paste -sd '|' -)"

# JSON rendering must stay valid for a normal budget, a zero budget, an empty
# budget and a skipped CPU sample (--fast).
valid_json() { printf '%s' "$1" | python3 -m json.tool >/dev/null 2>&1; }
j_ok=$(render_json RUNAWAY 123 01:02:03 99.5 25769803776 1G 12 31457280 "total = 1.00M")
valid_json "$j_ok"; expect "json valid, normal budget" "0" "$?"
expect "json ratio, normal budget" "819.2" "$(printf '%s' "$j_ok" | python3 -c 'import json,sys; print(json.load(sys.stdin)["over_budget_x"])')"
j_zero=$(render_json OK 123 01:02:03 0.5 1048576 1M 12 0 "total = 1.00M")
valid_json "$j_zero"; expect "json valid, budget 0" "0" "$?"
expect "json null ratio, budget 0" "None" "$(printf '%s' "$j_zero" | python3 -c 'import json,sys; print(json.load(sys.stdin)["over_budget_x"])')"
j_none=$(render_json OK 123 01:02:03 "" 1048576 1M 12 "" "total = 1.00M")
valid_json "$j_none"; expect "json valid, no budget, no cpu" "0" "$?"
expect "json null cpu" "None" "$(printf '%s' "$j_none" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cpu_pct"])')"

# is_fseventsd guards the signal: this shell is not fseventsd.
is_fseventsd "$$"; expect "is_fseventsd rejects other PIDs" "1" "$?"

# run_to must not leave an orphaned sleep behind (PPID 1) and must still time out.
orph_before=$(ps -A -o ppid=,command= | awk '$1==1 && $2=="sleep"' | wc -l)
for _ in 1 2 3 4 5 6 7 8 9 10; do run_to 30 true; done
run_to 1 sleep 5; expect "run_to timeout rc (SIGKILL)" "137" "$?"
orph_after=$(ps -A -o ppid=,command= | awk '$1==1 && $2=="sleep"' | wc -l)
expect "run_to leaves no orphan sleep" "$orph_before" "$orph_after"

# evidence_ok accepts a real listing and rejects an error message or an empty file.
ev_tmp=$(mktemp -d)
printf '%s\n' "$listing_dm" >"$ev_tmp/fseventsd-dir.txt"
evidence_ok "$ev_tmp"; expect "evidence_ok: real listing" "0" "$?"
printf 'ls: /System/Volumes/Data/.fseventsd: Operation not permitted\n' >"$ev_tmp/fseventsd-dir.txt"
evidence_ok "$ev_tmp"; expect "evidence_ok: error text only" "1" "$?"
: >"$ev_tmp/fseventsd-dir.txt"
evidence_ok "$ev_tmp"; expect "evidence_ok: empty file" "1" "$?"
mv "$ev_tmp" "${TMPDIR:-/tmp}/selftest-trash-$$" 2>/dev/null

if [ "${SELFTEST_BREAK:-0}" = "1" ]; then
  # Deliberately wrong: a runaway must NOT be reported as OK.
  check_verdict "BREAK (intentionally wrong)" $((24 * GB)) 99 OK 0
fi

echo "$((total - fails))/$total passed"
if [ "$fails" -ne 0 ]; then exit 1; fi
exit 0
