#!/usr/bin/env bash
# Renders a volunteer-friendly digest of the instrumentation run to the GitHub Actions
# run summary page ($GITHUB_STEP_SUMMARY). It parses the JUnit XML the connected suite
# writes, so a volunteer reads pass/fail WITHOUT opening any gradle/emulator log. The
# FULL HTML report + XML live in the uploaded artifact; this is the DIGEST only (the
# step summary has a 1 MiB / 20-per-job limit, so keep it small).
#
# It is called from a dedicated workflow step with `if: always()`, so it runs on a PASS
# AND on a FAIL. When no XML exists (the build failed before any test ran) it writes a
# plain "build failed before tests ran" line instead of erroring.
#
# Env (from the workflow):
#   GITHUB_STEP_SUMMARY  file the digest is appended to (set by Actions)
#   EXTENSIVE            "true" -> also render the 50x flake-hunt ledger
set -u

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
XML_DIR="treetracker-android/app/build/outputs/androidTest-results"
LEDGER="instrumentation-artifacts/extensive-ledger.csv"

# Android writes one TEST-<class>.xml per test class. Collect them all, sorted.
mapfile -t xmls < <(find "$XML_DIR" -name '*.xml' 2>/dev/null | sort)

{
  echo "## Instrumentation results"
  echo
} >> "$SUMMARY"

if [ "${#xmls[@]}" -eq 0 ]; then
  # No XML means the build failed or the emulator did not boot before any test ran.
  echo ":warning: No test results found. The build failed before the tests ran, or the emulator did not boot. See the log and the instrumentation-report artifact." >> "$SUMMARY"
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

# Per-class breakdown so a volunteer sees WHICH class failed, still without the log.
{
  echo "<details><summary>Per test class</summary>"
  echo
  echo "| Test class | Tests | Failed | Errors | Skipped |"
  echo "| --- | ---: | ---: | ---: | ---: |"
} >> "$SUMMARY"
for f in "${xmls[@]}"; do
  awk '
    function attr(line, name,   re, v) {
      re = name "=\"[^\"]*\""
      if (match(line, re)) {
        v = substr(line, RSTART, RLENGTH)
        sub(name "=\"", "", v); sub("\"$", "", v)
        return v
      }
      return ""
    }
    /<testsuite / {
      printf "| %s | %s | %s | %s | %s |\n", attr($0,"name"), attr($0,"tests"), attr($0,"failures"), attr($0,"errors"), attr($0,"skipped")
    }
  ' "$f" >> "$SUMMARY"
done
{
  echo
  echo "</details>"
  echo
} >> "$SUMMARY"

# On the 50x flake-hunt, render the per-iteration ledger + a one-line verdict.
if [ "${EXTENSIVE:-false}" = "true" ] && [ -f "$LEDGER" ]; then
  runs=$(($(wc -l < "$LEDGER") - 1))
  fails=$(awk -F, 'NR>1 && $3=="fail"' "$LEDGER" | wc -l)
  {
    echo "## 50x flake-hunt ledger"
    echo
    if [ "$fails" -eq 0 ]; then
      echo "**${runs}/50 pass, 0 flakes.**"
    else
      echo "**${fails} of ${runs} iterations FAILED.**"
    fi
    echo
    echo "<details><summary>Per iteration</summary>"
    echo
    echo "| Iteration | Seconds | Result |"
    echo "| ---: | ---: | --- |"
    awk -F, 'NR>1 { printf "| %s | %s | %s |\n", $1, $2, $3 }' "$LEDGER"
    echo
    echo "</details>"
  } >> "$SUMMARY"
fi
