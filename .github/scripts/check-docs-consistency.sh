#!/usr/bin/env bash
# Docs consistency check (issue: "Keep the docs current"). It asserts a structural invariant:
# every git submodule and every k3s stand-up adapter is documented. It reads facts from the
# source of truth (`.gitmodules`, `k3s/services/*/standalone.yaml`) and checks they are named
# in the docs (`README.md` Submodules section, `docs/component-coverage.md`). It judges SET
# MEMBERSHIP, never prose. Research backing + design rationale:
# .scratch/estate-coverage/research/ci-docs-currency-best-practice.md.
#
# It FAILS the build (exit 1) when a submodule or adapter is undocumented, and names the exact
# offenders, so a contributor who adds one but forgets the docs sees it on their own change.
#
# Escape hatches for the rare legitimate exception (a temporary/experimental submodule or
# adapter not yet documented):
#   - Per-entry allowlist: one name per line in `.github/docs-consistency-allow.txt`
#     (`#` comments and blank lines ignored). An allowlisted name is skipped in every check.
#   - Global warn-only: set `DOCS_CHECK_WARN_ONLY=1` to downgrade every finding to a warning
#     and exit 0.
#
# Root: reads under `$REPO_ROOT` (default the current directory), so the test harness can point
# it at a fixture tree.
set -u

ROOT="${REPO_ROOT:-.}"
GITMODULES="$ROOT/.gitmodules"
SERVICES_DIR="$ROOT/k3s/services"
README="$ROOT/README.md"
COVERAGE="$ROOT/docs/component-coverage.md"
ALLOWFILE="$ROOT/.github/docs-consistency-allow.txt"
WARN_ONLY="${DOCS_CHECK_WARN_ONLY:-0}"

# --- gather the source-of-truth sets -------------------------------------------------------

# Submodule names = basename of each `path =` in .gitmodules.
submodules=()
if [ -f "$GITMODULES" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] && submodules+=("$(basename "$p")")
  done < <(git config -f "$GITMODULES" --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')
fi

# Adapter subsystems = the dir name of each k3s/services/<name>/standalone.yaml marker.
adapters=()
if [ -d "$SERVICES_DIR" ]; then
  while IFS= read -r d; do
    adapters+=("$(basename "$(dirname "$d")")")
  done < <(find "$SERVICES_DIR" -maxdepth 2 -type f -name standalone.yaml 2>/dev/null | sort)
fi

# --- allowlist -----------------------------------------------------------------------------

is_allowed() {
  [ -f "$ALLOWFILE" ] || return 1
  local name="$1" line
  while IFS= read -r line; do
    line="${line%%#*}"                    # strip trailing comment
    line="$(echo "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && [ "$line" = "$name" ] && return 0
  done < "$ALLOWFILE"
  return 1
}

# --- doc corpora ---------------------------------------------------------------------------

# The README Submodules section: from `## Submodules` to the next level-2 heading.
readme_submodules_section=""
if [ -f "$README" ]; then
  readme_submodules_section="$(awk '/^## +Submodules/{f=1; next} /^## /{f=0} f' "$README")"
fi
coverage_text=""
[ -f "$COVERAGE" ] && coverage_text="$(cat "$COVERAGE")"

# A submodule is documented when its backtick-wrapped name appears. The backticks make it an
# exact match, so a shorter name is never satisfied by a longer one (`bulk-pack` != `bulk-pack-v2`).
named_in() { grep -qF -- "\`$2\`" <<<"$1"; }
# An adapter subsystem is a prose word (Gateway, LocalStack, wallet-app); match it as a WHOLE
# word, case-insensitively. Whole-word matching (not a bare substring) stops a shorter name
# from matching inside a longer one. This is looser than the backtick-exact submodule check,
# because adapters are documented in prose, not backticks; the residual risk (an adapter name
# that also appears in unrelated prose) is caught by the periodic doc sweep, and the strong
# guarantee stays the exact submodule checks above.
mentioned_in() { grep -qiwF -- "$2" <<<"$1"; }

# --- run the checks ------------------------------------------------------------------------

missing_readme=()
missing_coverage=()
missing_adapter=()

for s in "${submodules[@]:-}"; do
  [ -z "$s" ] && continue
  is_allowed "$s" && continue
  named_in "$readme_submodules_section" "$s" || missing_readme+=("$s")
  named_in "$coverage_text" "$s" || missing_coverage+=("$s")
done

for a in "${adapters[@]:-}"; do
  [ -z "$a" ] && continue
  is_allowed "$a" && continue
  mentioned_in "$coverage_text" "$a" || missing_adapter+=("$a")
done

# --- report --------------------------------------------------------------------------------

total_missing=$(( ${#missing_readme[@]} + ${#missing_coverage[@]} + ${#missing_adapter[@]} ))

if [ "$total_missing" -eq 0 ]; then
  echo "Docs consistency: OK. ${#submodules[@]} submodule(s) and ${#adapters[@]} adapter(s) are all documented; the docs are consistent."
  exit 0
fi

# Build a human-readable, actionable report that names every offender.
report() {
  [ "${#missing_readme[@]}" -gt 0 ] && \
    echo "  - Missing from README.md '## Submodules' section: ${missing_readme[*]}"
  [ "${#missing_coverage[@]}" -gt 0 ] && \
    echo "  - Missing from docs/component-coverage.md: ${missing_coverage[*]}"
  [ "${#missing_adapter[@]}" -gt 0 ] && \
    echo "  - Adapter(s) not documented in docs/component-coverage.md: ${missing_adapter[*]}"
  echo "Add the missing entries in the SAME change, or add a name to .github/docs-consistency-allow.txt if the omission is intentional (temporary/experimental)."
}

if [ "$WARN_ONLY" = "1" ]; then
  echo "::warning title=Docs consistency drift::${total_missing} undocumented submodule(s)/adapter(s). Warn-only mode is on, so the build is not failed."
  echo "Docs consistency: WARNING (${total_missing} undocumented; warn-only mode)."
  report
  exit 0
fi

echo "::error title=Docs consistency drift::${total_missing} submodule(s)/adapter(s) are not documented. See the details below and update the docs in this change."
echo "Docs consistency: FAILED. ${total_missing} item(s) are not documented:"
report
exit 1
