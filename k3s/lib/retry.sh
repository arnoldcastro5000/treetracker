# Shared retry helper for the k3s scripts (up.sh / down.sh / prepare-linux.sh via
# orchestrator-lib.sh or sourced directly). Sourced, not executed. Self-contained: no
# dependency on the callers' logging or config. Portable: bash 3.2 (macOS) + Linux.
#
# Design (ticket 28, .scratch/volunteer-e2e-ci/issues/28-standup-retry-parameters.md):
# ONE deadline-driven retry seam replaces the per-site attempts-x-fixed-sleep loops, so
# the budget is wall-clock (what both audiences care about), backoff is exponential with
# FULL jitter (de-synchronizes many volunteers + parallel CI runners hitting one registry),
# and deterministic failures fast-fail via a probe instead of burning the whole budget.
#
#   retry <deadline_s> <label> <command...>
#
# Returns the command's exit code (0 on success). ALWAYS call as a condition
# (`retry ... || die ...`): under `set -e` a bare failing call would abort mid-loop.
#
# Knobs (env; every one has a default so call sites stay one line):
#   RETRY_BUDGET_SCALE   multiply every deadline + attempt timeout (default 1). The one
#                        knob a volunteer on a slow link turns up (e.g. 3) and CI turns
#                        down (e.g. 0.6). Decimals accepted.
#   RETRY_MAX_ATTEMPTS   hard attempt cap inside the deadline (default 0 = unlimited).
#   RETRY_ATTEMPT_TIMEOUT  per-attempt kill for commands that can hang forever, in
#                        seconds, scaled (default 0 = none). Pure-bash watchdog, NOT the
#                        external `timeout` binary: the command may be a shell FUNCTION
#                        (which an external binary cannot exec - it 127s), and stock
#                        macOS has no `timeout` at all.
#   RETRY_PROBE          eval'd ONCE after the first failed attempt: a deterministic-
#                        failure classifier (e.g. net_check_die, which exits with the
#                        real cause on a firewall block). If it RETURNS non-zero the
#                        failure is terminal: stop retrying, propagate the rc.
#   RETRY_BASE           backoff base seconds (default 1; tests set 0 for speed).
#   RETRY_CAP            backoff window cap seconds (default 30).
#
# The deadline bounds STARTING new attempts, never kills a legitimately slow in-flight
# attempt - only RETRY_ATTEMPT_TIMEOUT does that. So a volunteer's slow-but-healthy
# docker build is never cut short by the retry budget.

# warn() comes from the sourcing script when defined (matching its glyphs/colors);
# otherwise this minimal fallback keeps retry.sh standalone.
declare -F warn >/dev/null 2>&1 || warn() { echo "! $*" >&2; }

# <deadline> x <scale> -> integer seconds (awk: bash arithmetic has no decimals).
_retry_scaled() { awk -v d="$1" -v s="$2" 'BEGIN{printf "%d", d*s}'; }

# Public: scale a deadline/timeout by the budget knob, for call sites that need the
# scaled number itself (a poll-loop iteration count, a curl --max-time) rather than a
# wrapped command.
retry_scaled_deadline() { _retry_scaled "$1" "${RETRY_BUDGET_SCALE:-1}"; }

# Run <cmd...> with a <seconds> kill watchdog. Bash-level (fork + kill), so it times out
# shell functions as well as binaries and needs no `timeout` on the host. The child's
# children are not chased: the clients used here (docker, curl) are single processes.
_retry_run_timed() {
  local t="$1" pid wd rc; shift
  "$@" & pid=$!
  { sleep "$t" && kill "$pid" 2>/dev/null; } & wd=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  return "$rc"
}

# Backoff window for <attempt> given <base> <cap>: min(cap, base*2^(attempt-1)). base 0
# (test mode) is always 0; past attempt 16 the shift would overflow, and base*2^15 >= cap
# for any real base/cap, so clamp straight to cap there.
_retry_window() {
  local attempt="$1" base="$2" cap="$3" w
  if [ "$base" -le 0 ]; then w=0
  elif [ "$attempt" -ge 16 ]; then w="$cap"
  else w=$((base << (attempt - 1)))
  fi
  [ "$w" -gt "$cap" ] && w="$cap"
  printf '%s' "$w"
}

retry() {
  local deadline="$1" label="$2"; shift 2
  local scale="${RETRY_BUDGET_SCALE:-1}"
  local max="${RETRY_MAX_ATTEMPTS:-0}" base="${RETRY_BASE:-1}" cap="${RETRY_CAP:-30}"
  local eff atmo start="$SECONDS" attempt=0 rc win delay
  eff=$(_retry_scaled "$deadline" "$scale")
  atmo=$(_retry_scaled "${RETRY_ATTEMPT_TIMEOUT:-0}" "$scale")
  while :; do
    attempt=$((attempt + 1))
    if [ "$atmo" -gt 0 ]; then
      _retry_run_timed "$atmo" "$@"; rc=$?
    else
      "$@"; rc=$?
    fi
    [ "$rc" -eq 0 ] && return 0
    # 127/126 = command not found / not executable: deterministic, retrying cannot help
    # (cycle-1 regression: a 127 storm burned the whole 300s budget).
    if [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; then
      warn "$label: rc $rc (command not found/executable) is terminal, not retrying"
      return "$rc"
    fi
    if [ "$attempt" -eq 1 ] && [ -n "${RETRY_PROBE:-}" ]; then
      # The probe either exits the script itself with the real cause (net_check_die on a
      # block), returns non-zero (terminal: do not retry), or returns 0 (transient: go on).
      if ! eval "$RETRY_PROBE"; then
        warn "$label: terminal failure (probe), not retrying (rc $rc)"
        return "$rc"
      fi
    fi
    if [ "$max" -gt 0 ] && [ "$attempt" -ge "$max" ]; then
      warn "$label: giving up after $attempt attempts (rc $rc)"
      return "$rc"
    fi
    if [ $((SECONDS - start)) -ge "$eff" ]; then
      warn "$label: giving up after $attempt attempts / $((SECONDS - start))s (budget ${eff}s, rc $rc)"
      return "$rc"
    fi
    win=$(_retry_window "$attempt" "$base" "$cap")
    delay=$((RANDOM % (win + 1)))
    warn "$label: attempt $attempt failed (rc $rc), retrying in ${delay}s"
    sleep "$delay"
  done
}
