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
    # --console=plain gives flat line-based gradle output; the ::group:: folds each
    # iteration into one collapsed section so the log reads as a list, not a wall.
    echo "::group::Gradle connectedLocalAndroidTest (iteration ${i}/50)"
    if ./gradlew connectedLocalAndroidTest --no-daemon --console=plain; then
      result=pass
    else
      result=fail
      ec=1
    fi
    echo "::endgroup::"
    end=$(date +%s)
    echo "${i},$((end - start)),${result}" >> "$LEDGER"
    if [ "$result" = "fail" ]; then
      # ONE titled annotation, not one per assertion: it renders at the top of the run
      # summary so a volunteer reads the cause first, above the log.
      echo "::error title=Instrumentation flake-hunt failed::Iteration ${i}/50 failed. See the results table in the run summary and the instrumentation-report artifact."
      break
    fi
  done
else
  echo "::group::Gradle connectedLocalAndroidTest"
  ./gradlew connectedLocalAndroidTest --no-daemon --stacktrace --console=plain || ec=$?
  echo "::endgroup::"
  if [ "$ec" -ne 0 ]; then
    echo "::error title=Instrumentation tests failed::One or more instrumentation tests failed. See the results table in the run summary and the instrumentation-report artifact."
  fi
fi

# Give logcat a beat to flush, then tear the captures down and pull the recording.
sleep 2
kill "$SCREENREC_PID" 2>/dev/null || true
kill "$LOGCAT_PID" 2>/dev/null || true
sleep 2
adb pull /sdcard/instrumentation.mp4 "$ART/instrumentation.mp4" 2>/dev/null || true

exit "$ec"
