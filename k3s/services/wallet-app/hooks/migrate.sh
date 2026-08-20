#!/usr/bin/env bash
# pre hook: provision the wallet-app database (data-stores decision 04 + wallet-app decision 01).
# The orchestrator has already ensured the `wallet_app` database exists. This hook:
#   1. creates the `wallet` schema (wallet-api tables) and the `queue` schema + queue.message table
#      and its NOTIFY trigger (the wallets/creation plumbing apps/user LISTENs on; dormant until a
#      producer inserts a row);
#   2. runs wallet-api's db-migrate migrations into the `wallet` schema;
#   3. seeds one dummy api_key row so wallet-api's api-key handler passes locally.
# Runs against the shared Postgres through a short-lived port-forward (mirrors the capture hook).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)/orchestrator-lib.sh"
trap stop_pf EXIT

WAPI="$TT_ROOT/treetracker-wallet-api"
log "wallet-app db: schemas + queue plumbing + wallet-api migrations + api_key seed ($WALLET_APP_DB)"
start_pf

# 1. schemas + the wallets/creation queue plumbing (queue.message + NOTIFY trigger). gen_random_uuid
#    is core in Postgres 15, so no extension is needed here. Idempotent.
PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -d "$WALLET_APP_DB" -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || die "wallet-app schema/queue setup failed"
CREATE SCHEMA IF NOT EXISTS wallet;
CREATE SCHEMA IF NOT EXISTS queue;
CREATE TABLE IF NOT EXISTS queue.message (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel    text NOT NULL,
  data       jsonb,
  ack        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION queue.notify_message() RETURNS trigger AS $fn$
BEGIN
  PERFORM pg_notify(NEW.channel, json_build_object('id', NEW.id, 'channel', NEW.channel, 'data', NEW.data)::text);
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS message_notify ON queue.message;
CREATE TRIGGER message_notify AFTER INSERT ON queue.message
  FOR EACH ROW EXECUTE FUNCTION queue.notify_message();
SQL

# 2. wallet-api migrations into schema `wallet`. db-migrate reads database.json from the config dir
#    (database/); the file is gitignored, generated per-env, and removed after. `schema` lands every
#    unqualified createTable in the `wallet` schema (verified: 51 migrations -> wallet.* only).
npm_install_local "$WAPI"
cat > "$WAPI/database/database.json" <<EOF
{"local":{"driver":"pg","host":"127.0.0.1","port":5432,"database":"$WALLET_APP_DB","user":"postgres","password":"postgres","schema":"wallet"}}
EOF
# Pass --config + --migrations-dir as absolute paths and DO NOT cd into the subdir: launching node
# from a subdir under virtiofs can fail process.cwd() (uv_cwd ENOENT). The repo root is a stable CWD.
db_migrate "$WAPI" up -e local --config "$WAPI/database/database.json" --migrations-dir "$WAPI/database/migrations" >/dev/null \
  || { rm -f "$WAPI/database/database.json"; die "wallet-api migrate failed"; }
rm -f "$WAPI/database/database.json"

# 3. seed the dummy api_key row (idempotent). Value via psql -v :'key' (no raw interpolation).
PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -d "$WALLET_APP_DB" -v ON_ERROR_STOP=1 -v key="$WALLET_API_KEY" >/dev/null <<'SQL' || die "api_key seed failed"
INSERT INTO wallet.api_key (id, key, tree_token_api_access, name)
SELECT gen_random_uuid(), :'key', true, 'local-dev'
WHERE NOT EXISTS (SELECT 1 FROM wallet.api_key WHERE key = :'key');
SQL

stop_pf
info "wallet.* (wallet-api tables) + queue.message plumbing + api_key seed ready in $WALLET_APP_DB"
