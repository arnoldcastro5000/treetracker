#!/usr/bin/env bash
# pre hook: run the capture pipeline's migrations (data-stores decision: each subsystem owns its
# migrations; the orchestrator has already ensured the declared databases exist). Runs against
# the shared Postgres through a short-lived port-forward.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)/orchestrator-lib.sh"
trap stop_pf EXIT

log "db-migrate (treetracker, data_pipeline, field_data, treetracker-api)"
start_pf
npm_install_local "$NEXTGEN/treetracker"
npm_install_local "$NEXTGEN/data_pipeline"
# field-data uses schema=field_data; treetracker-api uses no schema (it relies on the
# treetracker,public search_path set below), matching each repo's expected local DB config.
ensure_db_json "$TT_ROOT/treetracker-field-data/database/database.json" field_data
ensure_db_json "$TT_ROOT/treetracker-api/database.json"
# nextgen migrations: each nextgen dir has its own db-migrate. field-data + treetracker-api
# reuse the treetracker one (the tool + pg driver), matching how the stack ran before.
( cd "$NEXTGEN/treetracker"   && db_migrate "$NEXTGEN/treetracker"   up -e local -t nextgen_migrations >/dev/null ) || die "treetracker nextgen migrate failed"
( cd "$NEXTGEN/data_pipeline" && db_migrate "$NEXTGEN/data_pipeline" up -e local -t nextgen_migrations >/dev/null ) || die "data_pipeline nextgen migrate failed"
( cd "$TT_ROOT/treetracker-field-data/database" && db_migrate "$NEXTGEN/treetracker" up -e local >/dev/null ) \
  || die "field_data migrate failed"
# treetracker-api owns grower_account/capture/tree/... in a `treetracker` schema.
# DB default search_path=treetracker,public so uuid_generate_v4/PostGIS stay reachable.
PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -d treetracker -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || die "treetracker schema setup failed"
CREATE SCHEMA IF NOT EXISTS treetracker;
ALTER DATABASE treetracker SET search_path TO treetracker, public;
SQL
( cd "$TT_ROOT/treetracker-api" && db_migrate "$NEXTGEN/treetracker" up -e local --migrations-dir database/migrations/ >/dev/null ) \
  || die "treetracker-api migrate failed"
stop_pf
info "public.trees + field_data.* + data_pipeline.bulk_tree_upload + treetracker.grower_account/capture/tree ready"
