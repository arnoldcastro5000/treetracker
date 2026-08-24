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

# --- issue #23: strip heavy guest apps to free RAM/CPU (target: 100% a11y) ------
# The strip list + rationale live in strip-guest.sh (single source of truth; the
# workflow's "generate stripped AVD" step runs the SAME script once pre-boot - route 1,
# research doc 24 - so this call is a belt-and-suspenders no-op when the cached
# pre-stripped AVD is in use).
bash "$(dirname "$0")/strip-guest.sh"
{ echo "== guest meminfo AFTER strip =="; adb shell cat /proc/meminfo 2>/dev/null | grep -E 'MemTotal|MemAvailable'; } \
  | tee test-artifacts/guest-meminfo-after-strip.txt || true
# ------------------------------------------------------------------------------

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
