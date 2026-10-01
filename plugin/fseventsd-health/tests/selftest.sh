#!/bin/bash
# Selftest for the fseventsd-health hook. SELFTEST_BREAK=1 injects a defect and must turn it red.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
H="$HERE/../hooks-handlers/session-start.sh"
pass=0; fail=0
GB=1073741824; MB=1048576

ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

# run <uname> <mem> <budget>: handler output in $OUT, exit code in $RC.
run() {
  OUT=$(FSEVENTSD_HEALTH_TEST=1 FSEVENTSD_HEALTH_FAKE_UNAME="$1" \
    FSEVENTSD_HEALTH_FAKE_MEM_BYTES="$2" FSEVENTSD_HEALTH_FAKE_BUDGET_BYTES="$3" bash "$H")
  RC=$?
}
valid_json() { printf '%s' "$1" | python3 -m json.tool >/dev/null 2>&1; }

# 1. healthy daemon is silent
run Darwin $((50 * MB)) $((30 * MB))
if [ -z "$OUT" ] && [ "$RC" -eq 0 ]; then ok "OK stays silent"; else bad "OK stays silent"; fi

# 2. WARN: valid JSON, size and multiple present
run Darwin $((300 * MB)) $((30 * MB))
if valid_json "$OUT" && [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'WARN' \
  && printf '%s' "$OUT" | grep -q '300.0 MB' && printf '%s' "$OUT" | grep -q '10x'; then
  ok "WARN gives valid JSON with size and multiple"; else bad "WARN gives valid JSON with size and multiple"; fi

# 3. RUNAWAY: valid JSON, size and multiple, fix command, both fields
run Darwin $((24 * GB)) $((30 * MB))
if valid_json "$OUT" && printf '%s' "$OUT" | grep -q 'RUNAWAY' \
  && printf '%s' "$OUT" | grep -q '24.0 GB' && printf '%s' "$OUT" | grep -q '819x' \
  && printf '%s' "$OUT" | grep -q 'systemMessage' && printf '%s' "$OUT" | grep -q 'additionalContext' \
  && printf '%s' "$OUT" | grep -q 'sudo kill -TERM'; then
  ok "RUNAWAY gives valid JSON with size, multiple, fix"; else bad "RUNAWAY gives valid JSON with size, multiple, fix"; fi

# 4. non-Darwin is silent even with a huge value
run Linux $((24 * GB)) $((30 * MB))
if [ -z "$OUT" ] && [ "$RC" -eq 0 ]; then ok "non-Darwin stays silent"; else bad "non-Darwin stays silent"; fi

# 5. missing budget falls back to 30 MB and says so
run Darwin $((3 * GB)) none
if valid_json "$OUT" && printf '%s' "$OUT" | grep -q '30.0 MB' && printf '%s' "$OUT" | grep -q 'default'; then
  ok "missing budget uses 30 MB default"; else bad "missing budget uses 30 MB default"; fi

# 6. garbage memory value is silent, exit 0
run Darwin "abc" $((30 * MB))
if [ -z "$OUT" ] && [ "$RC" -eq 0 ]; then ok "garbage input stays silent"; else bad "garbage input stays silent"; fi

# 7. boundary: exactly 200 MB is OK
run Darwin $((200 * MB)) $((30 * MB))
if [ -z "$OUT" ]; then ok "200 MB boundary is OK"; else bad "200 MB boundary is OK"; fi

# 8. no override honoured outside test mode (real measurement; healthy or not, rc must be 0)
OUT=$(FSEVENTSD_HEALTH_FAKE_MEM_BYTES=$((24 * GB)) bash "$H"); RC=$?
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '24.0 GB'; then ok "overrides ignored without TEST=1"; else bad "overrides ignored without TEST=1"; fi

# Defect injection: a check that must always fail when SELFTEST_BREAK=1.
if [ "${SELFTEST_BREAK:-0}" = "1" ]; then
  run Darwin $((50 * MB)) $((30 * MB))
  if [ -n "$OUT" ]; then ok "break check"; else bad "break check (injected: expects output where handler is silent)"; fi
fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
