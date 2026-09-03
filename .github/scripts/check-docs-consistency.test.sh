#!/usr/bin/env bash
# Test harness for check-docs-consistency.sh. It builds throwaway fixture repos, runs the
# check against each, and asserts the exit code + the message. No network, no real git repo
# state: the check reads plain files under a root dir, so a fixture is just a directory tree.
#
# Run: bash .github/scripts/check-docs-consistency.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check-docs-consistency.sh"
pass=0
fail=0

# Build a minimal, fully in-sync fixture at $1: 2 submodules + 1 adapter, both documented.
make_fixture() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/k3s/services/capture" "$root/docs" "$root/.github"
  cat > "$root/.gitmodules" <<'EOF'
[submodule "treetracker-api"]
	path = treetracker-api
	url = ../treetracker-api
[submodule "images-api"]
	path = images-api
	url = ../images-api
EOF
  : > "$root/k3s/services/capture/standalone.yaml"
  cat > "$root/README.md" <<'EOF'
# Repo

## Submodules

- `treetracker-api`: the core API.
- `images-api`: stores images.

## Testing

Nothing here.
EOF
  cat > "$root/docs/component-coverage.md" <<'EOF'
# Component coverage

| Component | Submodule | Local stand-up |
| --- | --- | --- |
| core API | `treetracker-api` | built (capture) |
| images API | `images-api` | built (capture) |
EOF
}

# assert <name> <expected-exit> <root> [expected-substring-in-output]
assert() {
  local name="$1" want="$2" root="$3" needle="${4:-}"
  local out rc
  out="$(REPO_ROOT="$root" bash "$CHECK" 2>&1)"; rc=$?
  local ok=1
  [ "$rc" -eq "$want" ] || ok=0
  if [ -n "$needle" ] && ! grep -qF "$needle" <<<"$out"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    echo "PASS: $name"; pass=$((pass + 1))
  else
    echo "FAIL: $name (exit $rc, want $want)"; echo "----- output -----"; echo "$out"; echo "------------------"
    fail=$((fail + 1))
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A. In sync -> pass.
make_fixture "$TMP/a"
assert "in-sync passes" 0 "$TMP/a" "consistent"

# B. Submodule missing from the README Submodules section -> fail, names it.
make_fixture "$TMP/b"
cat >> "$TMP/b/.gitmodules" <<'EOF'
[submodule "new-service"]
	path = new-service
	url = ../new-service
EOF
# document it in coverage but NOT in the README, so only the README check trips.
echo "| new | \`new-service\` | built |" >> "$TMP/b/docs/component-coverage.md"
assert "missing-from-readme fails" 1 "$TMP/b" "new-service"

# C. Submodule documented in the README Submodules section but NOT in coverage -> fail, and
# only the coverage check trips (isolates the coverage-only path from case B).
make_fixture "$TMP/c"
cat >> "$TMP/c/.gitmodules" <<'EOF'
[submodule "new-service"]
	path = new-service
	url = ../new-service
EOF
cat > "$TMP/c/README.md" <<'EOF'
# Repo

## Submodules

- `treetracker-api`: the core API.
- `images-api`: stores images.
- `new-service`: documented here, but not in coverage.

## Testing

Nothing here.
EOF
assert "missing-from-coverage fails" 1 "$TMP/c" "component-coverage.md"
# Isolation: the README check must NOT fire for case C (new-service IS in the README section).
c_out="$(REPO_ROOT="$TMP/c" bash "$CHECK" 2>&1)"
if grep -qF "Missing from README.md" <<<"$c_out"; then
  echo "FAIL: case C not isolated (README check fired)"; echo "$c_out"; fail=$((fail + 1))
else
  echo "PASS: case C isolates the coverage-only path"; pass=$((pass + 1))
fi

# D. Adapter dir with no mention in the coverage doc -> fail.
make_fixture "$TMP/d"
mkdir -p "$TMP/d/k3s/services/ghost"
: > "$TMP/d/k3s/services/ghost/standalone.yaml"
assert "undocumented-adapter fails" 1 "$TMP/d" "ghost"

# E. Allowlisted missing submodule -> pass (per-entry exception).
make_fixture "$TMP/e"
cat >> "$TMP/e/.gitmodules" <<'EOF'
[submodule "temp-service"]
	path = temp-service
	url = ../temp-service
EOF
printf '# temporary, not documented yet\ntemp-service\n' > "$TMP/e/.github/docs-consistency-allow.txt"
assert "allowlisted entry passes" 0 "$TMP/e" "consistent"

# F. Warn-only mode -> a real drift exits 0 but prints a warning.
make_fixture "$TMP/f"
cat >> "$TMP/f/.gitmodules" <<'EOF'
[submodule "new-service"]
	path = new-service
	url = ../new-service
EOF
out="$(REPO_ROOT="$TMP/f" DOCS_CHECK_WARN_ONLY=1 bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qiF "warning" <<<"$out"; then
  echo "PASS: warn-only downgrades to exit 0"; pass=$((pass + 1))
else
  echo "FAIL: warn-only (exit $rc)"; echo "$out"; fail=$((fail + 1))
fi

# G. Substring safety: a shorter submodule name is NOT satisfied by a longer one.
# `bulk` documented, but submodule `bulk-pack` is its own entry -> must still fail.
make_fixture "$TMP/g"
cat >> "$TMP/g/.gitmodules" <<'EOF'
[submodule "bulk-pack"]
	path = bulk-pack
	url = ../bulk-pack
EOF
echo "- \`bulk-pack-transformer\`: unrelated longer name." >> "$TMP/g/README.md"
echo "| x | \`bulk-pack-transformer\` | built |" >> "$TMP/g/docs/component-coverage.md"
assert "substring-safe: longer name does not satisfy shorter" 1 "$TMP/g" "bulk-pack"

echo
echo "===== $pass passed, $fail failed ====="
[ "$fail" -eq 0 ]
