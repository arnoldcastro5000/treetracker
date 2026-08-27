#!/usr/bin/env bash
# Collect the backend + Android-internal signals for the Capture Journey report,
# for the fingerprint recorded by the wdio run (test-artifacts/journey/run.json),
# and write them to test-artifacts/journey/probes.json.
#
# Run from apps/e2e, while the cluster is still up (before teardown). Every probe
# is best-effort: a missing signal becomes "unknown" (the report back-fills it
# from the next confirmed downstream hop) and the script always exits 0, so it can
# never break the CI run. See utils/capture-journey.mjs for how these are joined.

JOURNEY_DIR="test-artifacts/journey"
LOGCAT="test-artifacts/logcat.txt"
RUN="$JOURNEY_DIR/run.json"
OUT="$JOURNEY_DIR/probes.json"
mkdir -p "$JOURNEY_DIR"

# ── fingerprint (from the wdio run record) ─────────────────────────────────────
FP=""
if [ -f "$RUN" ]; then
  FP=$(grep -o '"fingerprint"[[:space:]]*:[[:space:]]*"[^"]*"' "$RUN" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi
echo "[journey] fingerprint='${FP}'"

# ── helpers ────────────────────────────────────────────────────────────────────
has_log() { [ -f "$LOGCAT" ] && grep -qF "$1" "$LOGCAT" 2>/dev/null; }

POD=$(kubectl -n data get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
psql_q() { # $1=db  $2=sql  -> trimmed single value (empty on any failure)
  [ -n "$POD" ] || { printf ''; return 0; }
  kubectl -n data exec -i "$POD" -- psql -U postgres -d "$1" -tAc "$2" 2>/dev/null | tr -d '[:space:]' || true
}

# One ISO 8601 UTC output format for every to_char timestamp query (the double-
# quoted T and Z are SQL literals). Shared so the format never drifts between
# queries. Used inside single quotes in the SQL: '${TS_FMT}'.
TS_FMT='YYYY-MM-DD"T"HH24:MI:SS"Z"'

# ── Android internals (logcat) ─────────────────────────────────────────────────
CAPTURE=absent; CAPTURE_EV="no CameraXApp capture line"
if has_log "Photo capture bypassed" || has_log "Photo capture succeeded"; then
  CAPTURE=present; CAPTURE_EV="CameraXApp capture line"
fi

BUNDLE=absent; BUNDLE_EV="no TreeUploader bundle line"
if has_log "Uploading Tree Bundle"; then
  BUNDLE=present; BUNDLE_EV="TreeUploader building bundle"
fi

UPLOAD=absent; UPLOAD_EV="no Bundle Tree Upload Completed"
if has_log "Bundle Tree Upload Completed"; then
  UPLOAD=present; UPLOAD_EV="Bundle Tree Upload Completed"
fi

# ── S3 (best-effort; unknown back-fills from ingest) ───────────────────────────
S3=unknown; S3_EV="not probed"; S3_TS=""
if command -v awslocal >/dev/null 2>&1; then
  if awslocal s3api list-objects-v2 --bucket treetracker-local-batch-uploads \
       --query 'Contents[].Key' --output text 2>/dev/null | grep -q '_captures.json'; then
    S3=present; S3_EV="_captures.json in bucket"
    # LastModified of the captures object (ISO 8601 already); "None" if not found.
    S3_TS=$(awslocal s3api list-objects-v2 --bucket treetracker-local-batch-uploads \
      --query "Contents[?contains(Key, '_captures.json')].LastModified | [0]" --output text 2>/dev/null)
    [ "$S3_TS" = "None" ] && S3_TS=""
  else
    S3=absent; S3_EV="no _captures.json in bucket"
  fi
fi

# ── ingest + processor (data_pipeline.bulk_tree_upload, keyed by fingerprint) ──
# created_at / processed_at are `timestamp without time zone` storing UTC, so the
# report reads them as UTC: format to ISO 8601 with a Z, no zone conversion.
INGEST=unknown; INGEST_EV="no DB access"; INGEST_TS=""
PROCESSOR=unknown; PROCESSOR_EV="no DB access"; PROCESSOR_TS=""
if [ -n "$POD" ] && [ -n "$FP" ]; then
  # An empty result means the query itself failed (no DB access): keep "unknown",
  # never invent a stop. Only a real numeric 0 counts as "absent".
  ROWS=$(psql_q data_pipeline "SELECT count(*) FROM public.bulk_tree_upload WHERE bulk_data::text LIKE '%${FP}%'")
  if [ -z "$ROWS" ]; then
    INGEST=unknown; INGEST_EV="ingest query failed"
  elif [ "$ROWS" -ge 1 ] 2>/dev/null; then
    INGEST=present; INGEST_EV="${ROWS} bulk_tree_upload row(s)"
    INGEST_TS=$(psql_q data_pipeline "SELECT to_char(created_at,'${TS_FMT}') FROM public.bulk_tree_upload WHERE bulk_data::text LIKE '%${FP}%' ORDER BY created_at LIMIT 1")
    PROC=$(psql_q data_pipeline "SELECT processed FROM public.bulk_tree_upload WHERE bulk_data::text LIKE '%${FP}%' LIMIT 1")
    if [ "$PROC" = "t" ]; then
      PAT=$(psql_q data_pipeline "SELECT (processed_at IS NOT NULL) FROM public.bulk_tree_upload WHERE bulk_data::text LIKE '%${FP}%' LIMIT 1")
      PROCESSOR=present
      if [ "$PAT" = "t" ]; then
        PROCESSOR_EV="processed=t, processed_at set"
        PROCESSOR_TS=$(psql_q data_pipeline "SELECT to_char(processed_at,'${TS_FMT}') FROM public.bulk_tree_upload WHERE bulk_data::text LIKE '%${FP}%' AND processed_at IS NOT NULL LIMIT 1")
      else
        PROCESSOR_EV="processed=t, processed_at null"
      fi
    elif [ "$PROC" = "f" ]; then
      PROCESSOR=absent; PROCESSOR_EV="processed=f (not yet processed)"
    else
      PROCESSOR=unknown; PROCESSOR_EV="processed query failed"
    fi
  else
    INGEST=absent; INGEST_EV="no bulk_tree_upload row for fingerprint"
  fi
fi

# ── transformer ────────────────────────────────────────────────────────────────
# Phase 1 has no per-fingerprint transformer signal, so this stays "unknown" and the
# report back-fills it to PASS when raw_capture (its output) lands. A reliable
# per-capture transformer error signal needs a marker in the transformer itself
# (Phase 2); a raw pod-log grep gives false stops from stale or other-capture errors.
TRANSFORMER=unknown; TRANSFORMER_EV="inferred from raw_capture"

# ── raw_capture (field_data.raw_capture, keyed by fingerprint note) ────────────
# created_at is timestamptz; convert to UTC for the report.
RAWCAP=unknown; RAWCAP_EV="no DB access"; RAWCAP_TS=""
if [ -n "$POD" ] && [ -n "$FP" ]; then
  RC=$(psql_q treetracker "SELECT count(*) FROM field_data.raw_capture WHERE note='${FP}'")
  if [ -z "$RC" ]; then
    RAWCAP=unknown; RAWCAP_EV="raw_capture query failed"
  elif [ "$RC" -ge 1 ] 2>/dev/null; then
    RAWCAP=present; RAWCAP_EV="${RC} raw_capture row(s)"
    RAWCAP_TS=$(psql_q treetracker "SELECT to_char(created_at AT TIME ZONE 'UTC','${TS_FMT}') FROM field_data.raw_capture WHERE note='${FP}' ORDER BY created_at LIMIT 1")
  else
    RAWCAP=absent; RAWCAP_EV="no raw_capture row for fingerprint"
  fi
fi

# ── verify (env-skipped -> skipped; otherwise the cucumber step decides) ───────
VERIFY_LINE=""
if [ -n "${E2E_SKIP_ADMIN_VERIFY:-}" ]; then
  VERIFY_LINE='  "verify": {"signal":"skipped","evidence":"E2E_SKIP_ADMIN_VERIFY"},'
fi

# ── write probes.json ──────────────────────────────────────────────────────────
# Only the probed backend hops (s3/ingest/processor/raw_capture) carry a "ts": the
# log-derived hops (capture/bundle/upload) and the inferred transformer have no
# queryable time, so they keep the 2-field shape. The report defaults a missing ts
# to blank.
{
  echo "{"
  [ -n "$VERIFY_LINE" ] && echo "$VERIFY_LINE"
  echo "  \"capture\": {\"signal\":\"$CAPTURE\",\"evidence\":\"$CAPTURE_EV\"},"
  echo "  \"bundle\": {\"signal\":\"$BUNDLE\",\"evidence\":\"$BUNDLE_EV\"},"
  echo "  \"upload\": {\"signal\":\"$UPLOAD\",\"evidence\":\"$UPLOAD_EV\"},"
  echo "  \"s3\": {\"signal\":\"$S3\",\"ts\":\"$S3_TS\",\"evidence\":\"$S3_EV\"},"
  echo "  \"ingest\": {\"signal\":\"$INGEST\",\"ts\":\"$INGEST_TS\",\"evidence\":\"$INGEST_EV\"},"
  echo "  \"processor\": {\"signal\":\"$PROCESSOR\",\"ts\":\"$PROCESSOR_TS\",\"evidence\":\"$PROCESSOR_EV\"},"
  echo "  \"transformer\": {\"signal\":\"$TRANSFORMER\",\"evidence\":\"$TRANSFORMER_EV\"},"
  echo "  \"raw_capture\": {\"signal\":\"$RAWCAP\",\"ts\":\"$RAWCAP_TS\",\"evidence\":\"$RAWCAP_EV\"}"
  echo "}"
} > "$OUT"

echo "[journey] wrote $OUT:"
cat "$OUT"
exit 0
