#!/usr/bin/env bash
# Emulator-side driver for the co-located Route 2 Android E2E job (issue #23).
#
# Extracted from the workflow's inline `script:` so it is ONE shell with a proper
# shebang - no nested `sh -c "bash -c '...'"` and no single-quote gymnastics -
# and so it is readable, editable, and shellcheck-able on its own. The
# android-emulator-runner action invokes this once (working-directory: apps/e2e),
# so CWD is apps/e2e and test-artifacts/ + node_modules/ resolve relative to it.
#
# Env (from the workflow): E2E_SPEC (required), E2E_FORCE_A11Y_SERVICE (optional
# override), APP_PACKAGE. The whole run + diagnostics + cleanup live here so the
# device log and on-fail state are ALWAYS captured before the (preserved) wdio
# exit code is returned.
#
# NOTE: the API-34 a11y "boot lottery" root cause is emulator GUEST RAM starvation
# (fixed via the action's ram-size input, ~33%->~64%), plus host CPU contention at
# boot and an irreducible per-boot jank floor - NOT a Compose/a11y bug. The a11y
# force below is harmless belt-and-suspenders, not the fix. See issue #23.

export PATH="$(pwd)/node_modules/.bin:$PATH"
APP_PACKAGE="${APP_PACKAGE:-org.greenstand.android.TreeTracker.local}"
mkdir -p test-artifacts

adb wait-for-device
adb shell setprop debug.e2e.realtree 1 || true
adb logcat -c || true

a11y_settings() {
  echo -n "enabled_accessibility_services="; adb shell settings get secure enabled_accessibility_services
  echo -n "accessibility_enabled=";          adb shell settings get secure accessibility_enabled
  echo -n "touch_exploration_enabled=";      adb shell settings get secure touch_exploration_enabled
}

# Confirm the raised guest RAM actually applied (ram-size input; issue #23 fix).
adb shell cat /proc/meminfo 2>/dev/null | grep -E 'MemTotal|MemAvailable' | tee test-artifacts/guest-meminfo.txt || true

{ echo "== host resources just before wdio =="; date -u; echo "nproc: $(nproc)"; free -h; uptime; } \
  | tee test-artifacts/host-resources-pre-wdio.txt || true
{ echo "== a11y settings pre-wdio =="; a11y_settings; } | tee test-artifacts/a11y-settings-pre.txt 2>&1 || true
adb shell dumpsys accessibility > test-artifacts/a11y-dumpsys-pre.txt 2>&1 || true

# Force accessibility on and bind a non-touch-exploration service (select-to-speak /
# accessibility menu preferred; touch exploration kept OFF so injected taps still work).
# E2E_FORCE_A11Y_SERVICE overrides discovery; falls back to the flag alone if none found.
adb shell settings put secure accessibility_enabled 1 || true
SVC="${E2E_FORCE_A11Y_SERVICE:-}"
if [ -z "$SVC" ]; then
  SVCS=$(adb shell pm query-services --components -a android.accessibilityservice.AccessibilityService 2>/dev/null \
    | tr -d '\r' | grep -E '^[a-zA-Z][a-zA-Z0-9_.]*[.][a-zA-Z0-9_.]*/[a-zA-Z0-9_.]+$' | sort -u)
  echo "installed a11y services:"; echo "$SVCS"
  SVC=$(echo "$SVCS" | grep -iE 'selecttospeak|accessibilitymenu' | head -1)
  [ -z "$SVC" ] && SVC=$(echo "$SVCS" | grep -ivE 'talkback|switchaccess' | head -1)
  [ -z "$SVC" ] && SVC=$(echo "$SVCS" | head -1)
fi
if [ -n "$SVC" ]; then
  echo "enabling a11y service: $SVC"
  adb shell settings put secure enabled_accessibility_services "$SVC" || true
  adb shell settings put secure accessibility_enabled 1 || true
  adb shell settings put secure touch_exploration_enabled 0 || true
  sleep 6
else
  echo "::warning::no installed a11y service discovered; running on the accessibility_enabled flag only"
fi
{ echo "== a11y settings AFTER force =="; a11y_settings; } | tee test-artifacts/a11y-settings-forced.txt 2>&1 || true
adb shell dumpsys accessibility > test-artifacts/a11y-dumpsys-forced.txt 2>&1 || true
adb shell cmd accessibility get-bound-services > test-artifacts/a11y-bound-services-forced.txt 2>&1 || true
[ "$(adb shell settings get secure accessibility_enabled 2>/dev/null | tr -d '\r')" = "1" ] \
  || echo "::warning::force-a11y premise did not hold: accessibility_enabled != 1 after put"
BOUND=$(adb shell settings get secure enabled_accessibility_services 2>/dev/null | tr -d '\r')
echo "$BOUND" | grep -qE '^[a-zA-Z][a-zA-Z0-9_.]*[.][a-zA-Z0-9_.]*/[a-zA-Z0-9_.]+$' \
  || echo "::warning::a11y service not well-formed/bound ($BOUND); exposure may fall back to the flag-only path"

# --- issue #23 NEXT ACTION 1: boot-before-k3d ---------------------------------
# The a11y "boot lottery" is decided at GUEST BOOT and is stable afterwards: a
# poisoned boot never recovers (spec retries on the SAME emulator always fail) and a
# won boot stays won. The discriminator is a Pixel-Launcher ANR during boot under
# host CPU pressure (see the AFK ledger, RES-6 + PHASE-4 finding). probe_only reaches
# ~83% because it boots on a QUIET host; the full pipeline stalled at ~64% because the
# k3d control plane was already contending for the shared 4-core runner DURING boot.
# So the action above booted the emulator FIRST (the stack is not up yet). We now WAIT
# for the a11y tree to actually expose (the lottery has resolved), and only THEN stand
# up the backend. Onboarding-time contention is tolerable; boot-time contention is not.
REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/../../.." && pwd)}"
if [ "${PROBE_ONLY:-}" != "1" ]; then
  # Wait for UiAutomator to see a non-trivial tree = Compose semantics exposed = the
  # boot won the lottery. Up to 90s; a winner exposes fast, a loser never will.
  echo "== wait for a11y exposure before standing up the backend (boot-before-k3d) =="
  # uiautomator dump FAILS or returns a trivial tree on a poisoned boot (the a11y
  # bridge dropped - the exact #23 signature); it succeeds with a real hierarchy once
  # the boot has won. Redirection runs ON THE DEVICE (quoted), reading the device file.
  a11y_exposed=0
  for _ in $(seq 1 30); do
    if adb shell uiautomator dump /sdcard/settle.xml >/dev/null 2>&1; then
      sz=$(adb shell "wc -c < /sdcard/settle.xml" 2>/dev/null | tr -d '\r ')
      if [ "${sz:-0}" -gt 600 ] 2>/dev/null; then a11y_exposed=1; break; fi
    fi
    sleep 3
  done
  { echo "a11y_exposed_pre_standup=$a11y_exposed"; echo -n "host load: "; uptime; } \
    | tee test-artifacts/pre-standup-settle.txt || true
  if [ "$a11y_exposed" = 1 ]; then
    echo "a11y exposed on the quiet boot; standing up the backend now"
  else
    echo "::warning::a11y NOT exposed within 90s on the quiet boot (boot likely lost the lottery); standing up anyway so the run fails with the usual diagnostics"
  fi

  echo "== stand up local stack post-boot (quiet boot preserved) =="
  if ! ( cd "$REPO_ROOT" && ./k3s/up.sh capture && ./k3s/up.sh verify capture ); then
    echo "::error::backend standup/verify failed after emulator boot"
    exit 1
  fi

  if [ "${STAGE:-}" = "2" ]; then
    # Stage-2 fidelity baseline MUST be captured before wdio uploads. The later
    # "Assert upload landed" job step reads this file (the k3d kubeconfig up.sh wrote
    # persists in the default location across job steps).
    POD=$(kubectl -n data get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$POD" ]; then
      BASE=$(kubectl -n data exec -i "$POD" -- \
        psql -U postgres -d treetracker -tAc "SELECT count(*) FROM field_data.raw_capture" 2>/dev/null | tr -d '\r ')
      echo "${BASE:-0}" > test-artifacts/raw_capture_baseline.txt
      echo "raw_capture baseline = ${BASE:-0}"
    else
      echo "::warning::no postgres pod for the stage-2 baseline; defaulting to 0"
      echo "0" > test-artifacts/raw_capture_baseline.txt
    fi
  fi
fi
# ------------------------------------------------------------------------------

# Background helpers, all killed at the end:
#  - logcat capture (CameraX bind path + the .local bypass Timber line);
#  - GPS keep-alive: the emulator emits its default fix only ~3 min post-boot, but the
#    slow real-camera flow reaches GPS convergence later, so re-inject every 2s. Alternate
#    two points ~0.2m apart (below the ~1m std-dev threshold, so convergence still succeeds)
#    so consecutive fixes differ and cannot be deduped into no update;
#  - a11y timeline: dumpsys accessibility every 3s for the poisoned-vs-good diff.
adb logcat > test-artifacts/logcat.txt 2>&1 & LPID=$!
( i=0; while true; do
    if [ $((i % 2)) -eq 0 ]; then adb emu geo fix -123.150032 39.237255 >/dev/null 2>&1
    else adb emu geo fix -123.150034 39.237255 >/dev/null 2>&1; fi
    i=$((i + 1)); sleep 2
  done ) & GPID=$!
( while true; do echo "== $(date -u +%H:%M:%S) =="; adb shell dumpsys accessibility 2>/dev/null | sed -n '1,50p'; sleep 3; done ) \
  > test-artifacts/a11y-timeline.txt 2>&1 & APID=$!

adb shell dumpsys media.camera > test-artifacts/camera-dumpsys-before.txt 2>&1 || true

./node_modules/.bin/wdio run ./wdio.conf.ts --spec "features/$E2E_SPEC"
ec=$?

adb shell dumpsys media.camera > test-artifacts/camera-dumpsys-after.txt 2>&1 || true

# On failure, capture what was on screen (an ANR dialog or an empty tree) + an ANR trace.
if [ "$ec" -ne 0 ]; then
  PID=$(adb shell pidof "$APP_PACKAGE" 2>/dev/null | tr -d '\r')
  [ -n "$PID" ] && adb shell kill -3 "$PID" 2>/dev/null || true
  sleep 4
  adb shell dumpsys accessibility > test-artifacts/a11y-dumpsys-onfail.txt 2>&1 || true
  adb shell dumpsys window > test-artifacts/window-dumpsys-onfail.txt 2>&1 || true
  adb shell uiautomator dump /sdcard/win.xml >/dev/null 2>&1 \
    && adb pull /sdcard/win.xml test-artifacts/uiautomator-dump-onfail.xml >/dev/null 2>&1 || true
  adb shell dumpsys SurfaceFlinger --latency > test-artifacts/surfaceflinger-onfail.txt 2>&1 || true
  adb shell dumpsys activity top > test-artifacts/activity-top-onfail.txt 2>&1 || true
  adb shell cmd accessibility get-bound-services > test-artifacts/a11y-bound-services-onfail.txt 2>&1 || true
fi

sleep 2
kill "$LPID" "$APID" "$GPID" 2>/dev/null || true
exit "$ec"
