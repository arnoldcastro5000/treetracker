#!/usr/bin/env bash
# retry contract test - exercises the shared retry helper (k3s/lib/retry.sh) at its seam,
# without a cluster or network. Style-matched to orchestrator-test.sh. Portable: bash 3.2
# (macOS) + Linux. Tests run with RETRY_BASE=0 (no backoff sleeps) so the suite is fast.
#
# Run: ./k3s/retry-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/retry.sh"

PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fixture: fail_until <counter-file> <n> - exits 1 until called n times, then 0.
fail_until() {
  local f="$1" n="$2" c=0
  [ -f "$f" ] && c=$(cat "$f")
  c=$((c + 1)); echo "$c" > "$f"
  [ "$c" -ge "$n" ]
}
# fixture: exit_with <rc> - always fails with a distinctive exit code.
exit_with() { return "$1"; }
# fixture: count_and_fail <counter-file> - count the call, always fail.
count_and_fail() { fail_until "$1" 999999; }

echo "== 1. success passes through untouched"
RETRY_BASE=0 retry 60 "noop" true
[ $? = 0 ] && ok "rc 0 on immediate success" || bad "rc not 0 on success"
: > "$TMP/c1"
RETRY_BASE=0 retry 60 "once" fail_until "$TMP/c1" 1
[ "$(cat "$TMP/c1")" = 1 ] && ok "command ran exactly once" || bad "ran $(cat "$TMP/c1") times"

echo "== 2. transient failure retried to success"
: > "$TMP/c2"
RETRY_BASE=0 retry 60 "transient" fail_until "$TMP/c2" 3
RC=$?
[ "$RC" = 0 ] && ok "rc 0 after transient failures" || bad "rc $RC after transient failures"
[ "$(cat "$TMP/c2")" = 3 ] && ok "took exactly 3 attempts" || bad "took $(cat "$TMP/c2") attempts"

echo "== 3. zero deadline means a single attempt"
: > "$TMP/c3"
RETRY_BASE=0 retry 0 "one-shot" count_and_fail "$TMP/c3" 2>/dev/null
RC=$?
[ "$RC" != 0 ] && ok "failure propagates" || bad "rc 0 on always-fail"
[ "$(cat "$TMP/c3")" = 1 ] && ok "exactly 1 attempt at deadline 0" || bad "$(cat "$TMP/c3") attempts at deadline 0"

echo "== 4. deadline bounds the retry window"
: > "$TMP/c4"
START=$SECONDS
RETRY_BASE=0 retry 1 "bounded" count_and_fail "$TMP/c4" 2>/dev/null
RC=$?; ELAPSED=$((SECONDS - START))
[ "$RC" != 0 ] && ok "gives up (rc $RC)" || bad "rc 0 on always-fail"
[ "$ELAPSED" -le 5 ] && ok "finished in ${ELAPSED}s (<=5s)" || bad "took ${ELAPSED}s"

echo "== 5. RETRY_MAX_ATTEMPTS caps attempts inside a large deadline"
: > "$TMP/c5"
RETRY_BASE=0 RETRY_MAX_ATTEMPTS=3 retry 600 "capped" count_and_fail "$TMP/c5" 2>/dev/null
[ "$(cat "$TMP/c5")" = 3 ] && ok "exactly 3 attempts" || bad "$(cat "$TMP/c5") attempts (want 3)"

echo "== 6. exit code of the last attempt propagates"
RETRY_BASE=0 RETRY_MAX_ATTEMPTS=2 retry 600 "code" exit_with 7 2>/dev/null
RC=$?
[ "$RC" = 7 ] && ok "rc 7 propagated" || bad "rc $RC (want 7)"

echo "== 7. RETRY_PROBE runs exactly once, after the first failure"
: > "$TMP/c7"; : > "$TMP/probe7"
RETRY_BASE=0 RETRY_MAX_ATTEMPTS=3 RETRY_PROBE="fail_until $TMP/probe7 999999 || true; true" \
  retry 600 "probed" count_and_fail "$TMP/c7" 2>/dev/null
[ "$(cat "$TMP/probe7")" = 1 ] && ok "probe ran once" || bad "probe ran $(cat "$TMP/probe7") times"
[ "$(cat "$TMP/c7")" = 3 ] && ok "retries continued after benign probe" || bad "$(cat "$TMP/c7") attempts (want 3)"

echo "== 8. a failing RETRY_PROBE is terminal (fast-fail, no more attempts)"
: > "$TMP/c8"
RETRY_BASE=0 RETRY_MAX_ATTEMPTS=5 RETRY_PROBE="false" \
  retry 600 "terminal" count_and_fail "$TMP/c8" 2>/dev/null
RC=$?
[ "$RC" != 0 ] && ok "terminal failure propagates" || bad "rc 0 after terminal probe"
[ "$(cat "$TMP/c8")" = 1 ] && ok "no attempt after terminal probe" || bad "$(cat "$TMP/c8") attempts (want 1)"

echo "== 9. RETRY_ATTEMPT_TIMEOUT kills a hanging attempt (external binary)"
START=$SECONDS
RETRY_BASE=0 RETRY_MAX_ATTEMPTS=2 RETRY_ATTEMPT_TIMEOUT=1 \
  retry 600 "hang" sleep 30 2>/dev/null
RC=$?; ELAPSED=$((SECONDS - START))
[ "$RC" != 0 ] && ok "hanging command fails (rc $RC)" || bad "rc 0 on hang"
[ "$ELAPSED" -le 6 ] && ok "killed fast (${ELAPSED}s for 2 attempts)" || bad "took ${ELAPSED}s"

echo "== 9b. RETRY_ATTEMPT_TIMEOUT works on a shell FUNCTION (cycle-1 regression: external"
echo "==     timeout cannot exec a function -> rc 127 storm)"
fn_ok() { true; }
RETRY_BASE=0 RETRY_ATTEMPT_TIMEOUT=5 retry 60 "fn" fn_ok
[ $? = 0 ] && ok "function runs under attempt timeout" || bad "function failed under attempt timeout"
fn_hang() { sleep 30; }
START=$SECONDS
RETRY_BASE=0 RETRY_MAX_ATTEMPTS=2 RETRY_ATTEMPT_TIMEOUT=1 \
  retry 600 "fn-hang" fn_hang 2>/dev/null
RC=$?; ELAPSED=$((SECONDS - START))
[ "$RC" != 0 ] && ok "hanging function fails (rc $RC)" || bad "rc 0 on hanging function"
[ "$ELAPSED" -le 6 ] && ok "function killed fast (${ELAPSED}s)" || bad "took ${ELAPSED}s"

echo "== 9c. rc 127/126 (command not found / not executable) is terminal, never retried"
: > "$TMP/c9c"
fn_127() { fail_until "$TMP/c9c" 999999 >/dev/null; return 127; }
RETRY_BASE=0 RETRY_MAX_ATTEMPTS=5 retry 600 "notfound" fn_127 2>/dev/null
RC=$?
[ "$RC" = 127 ] && ok "rc 127 propagated" || bad "rc $RC (want 127)"
[ "$(cat "$TMP/c9c")" = 1 ] && ok "no retry on rc 127" || bad "$(cat "$TMP/c9c") attempts on rc 127 (want 1)"

echo "== 10. RETRY_BUDGET_SCALE=0 collapses the deadline to a single attempt"
: > "$TMP/c10"
RETRY_BASE=0 RETRY_BUDGET_SCALE=0 retry 600 "scaled" count_and_fail "$TMP/c10" 2>/dev/null
[ "$(cat "$TMP/c10")" = 1 ] && ok "1 attempt at scale 0" || bad "$(cat "$TMP/c10") attempts at scale 0"

echo "== 11. RETRY_BUDGET_SCALE accepts decimals"
EFF=$(_retry_scaled 100 0.6)
[ "$EFF" = 60 ] && ok "100 x 0.6 = 60" || bad "100 x 0.6 = $EFF"
EFF=$(_retry_scaled 300 1)
[ "$EFF" = 300 ] && ok "300 x 1 = 300" || bad "300 x 1 = $EFF"
EFF=$(RETRY_BUDGET_SCALE=0.5 retry_scaled_deadline 100)
[ "$EFF" = 50 ] && ok "retry_scaled_deadline honors the knob (100 x 0.5 = 50)" || bad "retry_scaled_deadline gave $EFF (want 50)"
EFF=$(retry_scaled_deadline 100)
[ "$EFF" = 100 ] && ok "retry_scaled_deadline default scale 1" || bad "retry_scaled_deadline default gave $EFF (want 100)"

echo "== 12. backoff window: capped, never negative"
W=$(_retry_window 1 1 30);  [ "$W" = 1 ]  && ok "attempt 1 window 1"  || bad "attempt 1 window $W"
W=$(_retry_window 5 1 30);  [ "$W" = 16 ] && ok "attempt 5 window 16" || bad "attempt 5 window $W"
W=$(_retry_window 9 1 30);  [ "$W" = 30 ] && ok "attempt 9 capped 30" || bad "attempt 9 window $W"
W=$(_retry_window 40 1 30); [ "$W" = 30 ] && ok "attempt 40 capped (no overflow)" || bad "attempt 40 window $W"
W=$(_retry_window 3 0 30);  [ "$W" = 0 ]  && ok "base 0 window 0 (test mode)" || bad "base 0 window $W"
W=$(_retry_window 20 0 30); [ "$W" = 0 ]  && ok "base 0 window 0 past the shift clamp" || bad "base 0 attempt 20 window $W (want 0)"

echo "== 13. argument fidelity: spaces in args survive"
RETRY_BASE=0 retry 60 "args" bash -c 'printf %s "$1" > "$2"' _ "two words" "$TMP/args13"
[ "$(cat "$TMP/args13")" = "two words" ] && ok "arg with space preserved" || bad "arg mangled: '$(cat "$TMP/args13")'"

echo
echo "== result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
