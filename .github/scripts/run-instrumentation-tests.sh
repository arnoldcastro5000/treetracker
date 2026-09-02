#!/usr/bin/env bash
# Runs the treetracker-android Compose instrumentation suite on the booted emulator.
#
# It is called from ONE line of the android-emulator-runner `script:` block, because
# that action runs each script LINE as a separate `sh -c` and aborts on the first
# non-zero line (so multi-line inline logic there is unsafe). Keeping the whole
# capture + run + teardown in this file guarantees the device log is always pulled
# before a test failure propagates as the job's exit code.
#
# Env (from the workflow):
#   GITHUB_WORKSPACE  repo root (set by Actions)
#   EXTENSIVE         "true" runs the 50x flake-hunt harness; anything else = one pass
set -u

ART="${GITHUB_WORKSPACE}/instrumentation-artifacts"
mkdir -p "$ART"

# Stream the full device log for the whole run; killed at the end.
adb logcat > "$ART/logcat.txt" 2>&1 &
LOGCAT_PID=$!

# Best-effort screen recording (180s cap is plenty for the hermetic suite). Never
# fails the run; some headless swiftshader emulators refuse screenrecord.
adb shell screenrecord --time-limit 180 /sdcard/instrumentation.mp4 &
SCREENREC_PID=$!

cd "${GITHUB_WORKSPACE}/treetracker-android" || exit 1
chmod +x ./gradlew

ec=0
if [ "${EXTENSIVE:-false}" = "true" ]; then
  # 50x flake hunt: bar is ZERO failures. Record per-iteration timing so variance
  # is a tracked metric (mirrors the route2 ledger shape). Stop at the first red.
  LEDGER="$ART/extensive-ledger.csv"
  echo "iteration,seconds,result" > "$LEDGER"
  for i in $(seq 1 50); do
    start=$(date +%s)
    if ./gradlew connectedLocalAndroidTest --no-daemon; then
      result=pass
    else
      result=fail
      ec=1
    fi
    end=$(date +%s)
    echo "${i},$((end - start)),${result}" >> "$LEDGER"
    if [ "$result" = "fail" ]; then
      echo "::error::extensive run failed on iteration ${i}"
      break
    fi
  done
else
  ./gradlew connectedLocalAndroidTest --no-daemon --stacktrace || ec=$?
fi

# Give logcat a beat to flush, then tear the captures down and pull the recording.
sleep 2
kill "$SCREENREC_PID" 2>/dev/null || true
kill "$LOGCAT_PID" 2>/dev/null || true
sleep 2
adb pull /sdcard/instrumentation.mp4 "$ART/instrumentation.mp4" 2>/dev/null || true

exit "$ec"
