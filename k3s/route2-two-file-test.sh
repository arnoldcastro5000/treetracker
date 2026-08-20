#!/usr/bin/env bash
# Route 2 two-file acceptance test (capture-child ticket 18, backend half).
#
# The real Android `local` app uploads TWO SEPARATE files per session, not one combined pack:
#   <ts>_<session>_..._sessions.json   -> wallet_registrations + device_configurations + sessions
#   <ts>_<session>_..._captures.json   -> captures only (references the session)
# smoke.sh only proves a COMBINED pack injected at the DB boundary. This test proves the real
# two-file pattern flows through the FULL local object path (LocalStack S3 -> SQS -> bulk-pack-consumer
# -> data_pipeline -> processor -> v1/v2 transformers -> field_data.raw_capture), in BOTH orders:
#   A. sessions then captures (happy path)  -> capture lands.
#   B. captures BEFORE its sessions         -> orphaned (does not land), then SELF-HEALS once the
#      sessions file arrives and a later processor cycle reprocesses the captures row (ticket 19).
#
# No emulator: the remaining gap (the real APK actually producing these files/bytes) needs the
# emulator or CI, which the sandbox cannot run. This validates everything downstream of that.
#
# Portable across macOS (bash 3.2) and Linux; every kubectl call is pinned to the k3d context.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/e2e-lib.sh"

LOCALSTACK_NAME="${LOCALSTACK_NAME:-greenstand-localstack}"
LOCALSTACK_PORT="${LOCALSTACK_PORT:-4566}"
OBJECT_STORAGE_REGION="${OBJECT_STORAGE_REGION:-eu-central-1}"
BATCH_UPLOADS_BUCKET="${BATCH_UPLOADS_BUCKET:-treetracker-local-batch-uploads}"
# Processor is a 60s CronJob, so waits are in cycles. Tunable for a faster/slower box.
LAND_TRIES="${LAND_TRIES:-30}"       # ~150s to see a capture land
ORPHAN_TRIES="${ORPHAN_TRIES:-24}"   # ~120s (>=2 processor cycles) to confirm it stays orphaned

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 2; }
kubectl config get-contexts "$CONTEXT" >/dev/null 2>&1 || { echo "FATAL: kube context '$CONTEXT' not found"; exit 2; }
docker ps --filter "name=^/${LOCALSTACK_NAME}$" --filter status=running -q | grep -q . \
  || { echo "FATAL: LocalStack container '$LOCALSTACK_NAME' not running -- ./k3s/up.sh localstack"; exit 2; }

# Upload a JSON body to the batch-uploads bucket under $key, firing the S3 -> SQS notification.
s3put() {   # $1 = key  $2 = json string
  local key="$1" body="$2"
  printf '%s' "$body" | docker exec -i "$LOCALSTACK_NAME" sh -c "cat > /tmp/up.json" \
    || { bad "staging $key into localstack failed"; return 1; }
  docker exec "$LOCALSTACK_NAME" env AWS_DEFAULT_REGION="$OBJECT_STORAGE_REGION" \
    awslocal s3api put-object --bucket "$BATCH_UPLOADS_BUCKET" --key "$key" --body /tmp/up.json >/dev/null \
    || { bad "put-object $key failed"; return 1; }
}

# 0 iff the capture with note $1 is present in field_data.raw_capture. Uses >=1 (not ==1): the
# processor re-POSTs an unprocessed row every cycle, and a non-idempotent insert could duplicate,
# which must still read as "landed", never as a false failure.
landed()      { [ "$(num "$(psq treetracker "select count(*) from field_data.raw_capture where note='$1'")")" -ge 1 ]; }
# 0 iff the session $1 has replicated into field_data (its planter now exists, so captures for it
# can be processed). This is the robust "sessions pack is ready" signal, independent of the
# data_pipeline.processed flag.
session_ready(){ [ "$(num "$(psq treetracker "select count(*) from field_data.session where id='$1'")")" -ge 1 ]; }
ts()      { date -u +%Y-%m-%d-%H-%M-%S; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "== Route 2 two-file acceptance test (LocalStack S3 -> ... -> field_data.raw_capture)"

# ---------------------------------------------------------------------------
echo "== A. happy order: _sessions.json THEN _captures.json"
SES=$(uuid); WR=$(uuid); DC=$(uuid); CAP=$(uuid)
W="+1555$(date +%s)1"; FP="e2e-2f-a-$(date +%s)"; NOW=$(now_iso); STAMP=$(ts)
KEY_S="${STAMP}_${SES}_e2e_sessions.json"
KEY_C="${STAMP}_${SES}_e2e_captures.json"

s3put "$KEY_S" "$(pack_json "$WR" "$DC" "$SES" "$CAP" "$W" "$W" "$NOW" "$FP" 1 0)" && ok "uploaded $KEY_S"
# Let the sessions pack replicate (v1 -> planter/session) before the captures arrive.
SES_OK=0
for i in $(seq 1 "$LAND_TRIES"); do session_ready "$SES" && { SES_OK=1; break; }; sleep 5; done
[ "$SES_OK" = 1 ] && ok "sessions pack replicated to field_data.session after ~$(((i-1)*5))s" \
  || bad "sessions pack never reached field_data.session"
s3put "$KEY_C" "$(pack_json "$WR" "$DC" "$SES" "$CAP" "$W" "$W" "$NOW" "$FP" 0 1)" && ok "uploaded $KEY_C"
A_OK=0
for i in $(seq 1 "$LAND_TRIES"); do landed "$FP" && { A_OK=1; break; }; sleep 5; done
[ "$A_OK" = 1 ] && ok "capture landed in field_data.raw_capture after ~$(((i-1)*5))s (happy order)" \
  || bad "capture never landed after happy-order upload"

# ---------------------------------------------------------------------------
echo "== B. out-of-order: _captures.json BEFORE its _sessions.json (must orphan, then self-heal)"
SES=$(uuid); WR=$(uuid); DC=$(uuid); CAP=$(uuid)
W="+1555$(date +%s)2"; FP="e2e-2f-b-$(date +%s)"; NOW=$(now_iso); STAMP=$(ts)
KEY_S="${STAMP}_${SES}_e2e_sessions.json"
KEY_C="${STAMP}_${SES}_e2e_captures.json"

s3put "$KEY_C" "$(pack_json "$WR" "$DC" "$SES" "$CAP" "$W" "$W" "$NOW" "$FP" 0 1)" && ok "uploaded captures-first $KEY_C"
# Primary orphan signal: the capture must NOT reach raw_capture while its session is missing, across
# >=2 processor cycles. Corroborating: its bulk_tree_upload row stays processed=f (not yet healed;
# it flips to t only once the capture actually replicates).
ORPHANED=1
for i in $(seq 1 "$ORPHAN_TRIES"); do landed "$FP" && { ORPHANED=0; break; }; sleep 5; done
if [ "$ORPHANED" = 1 ]; then
  ok "captures-first NOT in raw_capture after ~$((ORPHAN_TRIES*5))s (orphaned, session missing)"
  PF=$(psq data_pipeline "select processed from public.bulk_tree_upload where key='$KEY_C'")
  [ "$PF" = "f" ] && ok "corroborated: its bulk_tree_upload row is processed=f (unhealed)" \
    || bad "captures-first not landed but processed=$PF (expected f while orphaned)"
else
  bad "captures-first landed WITHOUT its session (fidelity broken: ordering not enforced)"
fi
# Now deliver the session; the orphaned capture must self-heal on a later reprocess cycle.
s3put "$KEY_S" "$(pack_json "$WR" "$DC" "$SES" "$CAP" "$W" "$W" "$NOW" "$FP" 1 0)" && ok "uploaded the missing $KEY_S"
HEAL=0
for i in $(seq 1 "$LAND_TRIES"); do landed "$FP" && { HEAL=1; break; }; sleep 5; done
[ "$HEAL" = 1 ] && ok "orphaned capture self-healed into raw_capture after ~$(((i-1)*5))s" \
  || bad "orphaned capture never healed after its session arrived"

echo
echo "== result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
