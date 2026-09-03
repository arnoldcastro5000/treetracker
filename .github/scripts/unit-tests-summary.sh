#!/usr/bin/env bash
# Renders a volunteer-friendly digest of the JVM unit-test run to the GitHub Actions run
# summary page ($GITHUB_STEP_SUMMARY). It parses the JUnit XML that `./gradlew
# testLocalUnitTest` writes, so a volunteer reads pass/fail WITHOUT opening the gradle log.
# The FULL HTML report + XML live in the uploaded artifact; this is the DIGEST only (the
# step summary has a 1 MiB / 20-per-job limit, so keep it small).
#
# It is called from a dedicated workflow step with `if: always()`, so it runs on a PASS
# AND on a FAIL. When no XML exists (the build failed before any test ran) it writes a
# plain "build failed before tests ran" line instead of erroring. On failures it also
# emits ONE titled ::error so the cause sits at the top of the run summary.
#
# Unlike the connected instrumentation suite (ONE device-level <testsuite>), the JVM
# reports write one TEST-<class>.xml per class, each a proper <testsuite name="<class>">,
# so the per-class table reads each <testsuite> opening tag directly.
#
# Env (from the workflow):
#   GITHUB_STEP_SUMMARY  file the digest is appended to (set by Actions)
set -u

# Anchor at the workspace root, so the digest does not depend on the step's current dir.
WS="${GITHUB_WORKSPACE:-.}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
XML_DIR="${WS}/treetracker-android/app/build/test-results/testLocalUnitTest"

# Gradle writes one TEST-<class>.xml per test class. Collect them all, sorted.
mapfile -t xmls < <(find "$XML_DIR" -name '*.xml' 2>/dev/null | sort)

{
  echo "## Unit test results"
  echo
} >> "$SUMMARY"

if [ "${#xmls[@]}" -eq 0 ]; then
  # No XML means the build failed before any test ran (compile error, missing dep, ...).
  echo ":warning: No test results found. The build failed before the tests ran. See the log and the unit-test-report artifact." >> "$SUMMARY"
  echo "::error title=Unit tests failed::No test results found. The build failed before the tests ran. See the unit-test-report artifact."
  exit 0
fi

# Sum tests / failures / errors / skipped / time across every <testsuite> opening tag.
read -r tests failures errors skipped time_s < <(
  awk '
    function attr(line, name,   re, v) {
      re = name "=\"[0-9.]+\""
      if (match(line, re)) {
        v = substr(line, RSTART, RLENGTH)
        sub(name "=\"", "", v); sub("\"", "", v)
        return v + 0
      }
      return 0
    }
    /<testsuite / {
      tests    += attr($0, "tests")
      failures += attr($0, "failures")
      errors   += attr($0, "errors")
      skipped  += attr($0, "skipped")
      time_s   += attr($0, "time")
    }
    END { printf "%d %d %d %d %.1f\n", tests, failures, errors, skipped, time_s }
  ' "${xmls[@]}"
)

bad=$((failures + errors))
passed=$((tests - failures - errors - skipped))
if [ "$bad" -eq 0 ]; then
  verdict=":white_check_mark: PASSED"
else
  verdict=":x: FAILED"
fi

{
  echo "| Result | Total | Passed | Failed | Errors | Skipped | Time (s) |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"
  echo "| ${verdict} | ${tests} | ${passed} | ${failures} | ${errors} | ${skipped} | ${time_s} |"
  echo
} >> "$SUMMARY"

# Per-class breakdown so a volunteer sees WHICH class failed, still without the log. It is
# rendered ALWAYS EXPANDED (no <details> fold), so the full class list is visible at a glance.
# Each file is one <testsuite> whose `name` is the class FQN; strip the app's common root
# package so the table stays readable (a class outside it prints unchanged).
{
  echo "### Per test class"
  echo
  echo "| Test class | Tests | Failed | Errors | Skipped | Time (s) |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: |"
  awk '
    function attr(line, name, numeric,   re, v) {
      re = name "=\"" (numeric ? "[0-9.]+" : "[^\"]*") "\""
      if (match(line, re)) {
        v = substr(line, RSTART, RLENGTH)
        sub(name "=\"", "", v); sub("\"$", "", v)
        return v
      }
      return numeric ? "0" : ""
    }
    /<testsuite / {
      cls = attr($0, "name", 0)
      sub(/^org\.greenstand\.android\.TreeTracker\./, "", cls)
      printf "| %s | %d | %d | %d | %d | %.3f |\n", cls, \
        attr($0, "tests", 1), attr($0, "failures", 1), \
        attr($0, "errors", 1), attr($0, "skipped", 1), attr($0, "time", 1)
    }
  ' "${xmls[@]}" | sort
  echo
} >> "$SUMMARY"

# Link the source of truth: the tests are defined in the treetracker-android submodule, which
# the monorepo pins by gitlink and runs via `testLocalUnitTest`. Link that test source AT THE
# PINNED COMMIT, so a reader sees exactly which tests exist and how many run. The URL comes from
# the .gitmodules submodule URL (the fork), because the pinned commit is reachable there (the
# submodule's own origin may point at upstream, where the fork-only commit does not exist).
sm_dir="$WS/treetracker-android"
sm_sha="$(git -C "$sm_dir" rev-parse HEAD 2>/dev/null || true)"
sm_url="$(git config -f "$WS/.gitmodules" submodule.treetracker-android.url 2>/dev/null || true)"
if [ -n "$sm_sha" ] && [ -n "$sm_url" ]; then
  base="${sm_url%.git}"
  base="${base/git@github.com:/https://github.com/}"
  {
    echo "**Test source:** these tests are defined in the \`treetracker-android\` submodule at the pinned commit \`${sm_sha:0:12}\`: [\`app/src/test\`](${base}/tree/${sm_sha}/app/src/test). The monorepo pins this commit and runs \`testLocalUnitTest\`; that source dictates which tests exist and how many run."
    echo
  } >> "$SUMMARY"
fi

# On failure emit ONE titled annotation so the cause sits at the top of the run summary.
if [ "$bad" -ne 0 ]; then
  echo "::error title=Unit tests failed::${bad} test(s) failed. See the results table above and the unit-test-report artifact."
fi
