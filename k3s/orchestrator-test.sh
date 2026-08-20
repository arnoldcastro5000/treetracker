#!/usr/bin/env bash
# Orchestrator contract test - exercises up.sh adapter discovery, selection, ordering and
# validation WITHOUT a cluster. Uses `up.sh plan` (prints the resolved stand-up order, one
# adapter per line, no cluster contact) against the real adapters and against throwaway
# fixture adapter dirs (ADAPTERS_DIR override). Portable: bash 3.2 (macOS) + Linux.
#
# Run: ./k3s/orchestrator-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UP="$SCRIPT_DIR/up.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# plan <args...> -> stdout of `up.sh plan ...`; exit code in PLAN_RC
PLAN_RC=0
plan() { PLAN_OUT=$("$UP" plan "$@" 2>"$TMP/stderr"); PLAN_RC=$?; }
# line number of adapter <name> in $PLAN_OUT (empty if absent)
line_of() { printf '%s\n' "$PLAN_OUT" | grep -nx "$1" | head -1 | cut -d: -f1; }

# ── fixture builder ─────────────────────────────────────────────────────────
# fixture <dir> <name> <yaml-body...>
fixture() {
  local dir="$1" name="$2"; shift 2
  mkdir -p "$dir/$name"
  { echo "name: $name"; [ $# -gt 0 ] && printf '%s\n' "$@"; } > "$dir/$name/standalone.yaml"
}

echo "== 1. real adapters: bare plan resolves the capture stack in dependency order"
plan
[ "$PLAN_RC" = 0 ] && ok "plan exits 0" || bad "plan exited $PLAN_RC: $(cat "$TMP/stderr")"
for a in postgres gateway rabbitmq localstack capture; do
  [ -n "$(line_of "$a")" ] && ok "plan lists $a" || bad "plan does not list $a"
done
CAP=$(line_of capture)
for dep in postgres gateway rabbitmq localstack; do
  D=$(line_of "$dep")
  [ -n "$D" ] && [ -n "$CAP" ] && [ "$D" -lt "$CAP" ] \
    && ok "$dep before capture" || bad "$dep not before capture (dep=$D capture=$CAP)"
done

echo "== 2. real adapters: selective plan pulls transitive deps + universal tier"
plan capture
[ "$PLAN_RC" = 0 ] && ok "plan capture exits 0" || bad "plan capture exited $PLAN_RC"
for a in postgres gateway rabbitmq localstack capture; do
  [ -n "$(line_of "$a")" ] && ok "plan capture includes $a" || bad "plan capture misses $a"
done

echo "== 3. unknown subsystem fails loudly"
plan no-such-subsystem
[ "$PLAN_RC" != 0 ] && grep -q "no-such-subsystem" "$TMP/stderr" \
  && ok "unknown subsystem dies naming it" || bad "unknown subsystem not rejected (rc=$PLAN_RC)"

echo "== 4. fixtures: conditional tier included only when depended on"
FD="$TMP/fx-conditional"
fixture "$FD" base "tier: universal"
fixture "$FD" broker "tier: conditional"
fixture "$FD" store "tier: conditional"
fixture "$FD" appa "dependsOn: [broker]"
ADAPTERS_DIR="$FD" plan
[ -n "$(line_of appa)" ] && [ -n "$(line_of broker)" ] \
  && ok "all: subsystem + its conditional dep included" || bad "all: appa/broker missing"
[ -z "$(line_of store)" ] \
  && ok "all: unreferenced conditional tier excluded" || bad "all: store included with no dependent"
[ -n "$(line_of base)" ] \
  && ok "all: universal tier included" || bad "all: universal tier missing"

echo "== 5. fixtures: universal tier included even for an unrelated selection"
FD="$TMP/fx-universal"
fixture "$FD" base "tier: universal"
fixture "$FD" appa
ADAPTERS_DIR="$FD" plan appa
[ -n "$(line_of base)" ] && B=$(line_of base) && A=$(line_of appa) && [ "$B" -lt "$A" ] \
  && ok "universal tier stands up first" || bad "universal tier missing or not first"

echo "== 6. fixtures: optIn subsystem excluded from all, included when named"
FD="$TMP/fx-optin"
fixture "$FD" appa
fixture "$FD" extra "optIn: true"
ADAPTERS_DIR="$FD" plan
[ -z "$(line_of extra)" ] && ok "all: optIn excluded" || bad "all: optIn included"
ADAPTERS_DIR="$FD" plan extra
[ -n "$(line_of extra)" ] && ok "named: optIn included" || bad "named: optIn missing"

echo "== 7. fixtures: dependency ordering is transitive"
FD="$TMP/fx-order"
fixture "$FD" c "dependsOn: [b]"
fixture "$FD" b "dependsOn: [a]"
fixture "$FD" a
ADAPTERS_DIR="$FD" plan c
A=$(line_of a); B=$(line_of b); C=$(line_of c)
[ -n "$A" ] && [ -n "$B" ] && [ -n "$C" ] && [ "$A" -lt "$B" ] && [ "$B" -lt "$C" ] \
  && ok "a < b < c" || bad "transitive order broken (a=$A b=$B c=$C)"

echo "== 8. fixtures: validation failures die with the cause"
FD="$TMP/fx-collide"
fixture "$FD" one "namespaces: [shared-ns]"
fixture "$FD" two "namespaces: [shared-ns]"
ADAPTERS_DIR="$FD" plan
[ "$PLAN_RC" != 0 ] && grep -q "shared-ns" "$TMP/stderr" \
  && ok "namespace collision detected" || bad "namespace collision not detected (rc=$PLAN_RC)"

FD="$TMP/fx-unknown-dep"
fixture "$FD" appa "dependsOn: [ghost]"
ADAPTERS_DIR="$FD" plan
[ "$PLAN_RC" != 0 ] && grep -q "ghost" "$TMP/stderr" \
  && ok "unknown dependsOn detected" || bad "unknown dependsOn not detected (rc=$PLAN_RC)"

FD="$TMP/fx-cycle"
fixture "$FD" x "dependsOn: [y]"
fixture "$FD" y "dependsOn: [x]"
ADAPTERS_DIR="$FD" plan
[ "$PLAN_RC" != 0 ] && grep -qi "cycle" "$TMP/stderr" \
  && ok "dependency cycle detected" || bad "cycle not detected (rc=$PLAN_RC)"

echo "== 9. fixtures: verify verb runs the declared verify hook"
FD="$TMP/fx-verify"
MARK="$TMP/verify-ran"
cat > "$TMP/fake-verify.sh" <<EOF
#!/usr/bin/env bash
echo ran > "$MARK"
EOF
chmod +x "$TMP/fake-verify.sh"
fixture "$FD" appa "verify: $TMP/fake-verify.sh"
ADAPTERS_DIR="$FD" "$UP" verify appa >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && [ -f "$MARK" ] && ok "up.sh verify runs the hook" || bad "verify verb broken (rc=$RC, marker $([ -f "$MARK" ] && echo present || echo absent))"

rm -f "$MARK"
cat > "$TMP/fake-verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
ADAPTERS_DIR="$FD" "$UP" verify appa >/dev/null 2>&1
[ $? != 0 ] && ok "failing verify fails the run" || bad "failing verify did not fail the run"

echo "== 10. real adapters: capture declares smoke.sh as its verify"
V=$(yq -r '.verify // ""' "$SCRIPT_DIR/services/capture/standalone.yaml" 2>/dev/null)
[ "$V" = "k3s/smoke.sh" ] && ok "capture verify = k3s/smoke.sh" || bad "capture verify is '$V'"

echo
echo "== result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
