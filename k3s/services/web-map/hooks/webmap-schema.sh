#!/usr/bin/env bash
# pre hook: provision the webmap.* schema EMPTY (web-map-standalone decision 03). The enrichment
# objects are prod-only materialized views with no DDL in any repo; empty tables with the columns
# query-api selects make its LEFT JOINs resolve to NULL instead of 500. raw_capture_feature uses
# the consumer's real DDL (the opt-in consumer populates it later). NO config-row seed: the
# leaderboard ships disabled (decision 05). Idempotent; runs against the shared Postgres through
# a short-lived port-forward, matching the capture migrate hook.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)/orchestrator-lib.sh"
trap stop_pf EXIT

log "webmap schema (empty enrichment tables, decision 03)"
start_pf
PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -d treetracker -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || die "webmap schema provisioning failed"
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS webmap;

-- Enrichment objects: empty tables (prod = materialized views refreshed by airflow).
CREATE TABLE IF NOT EXISTS webmap.planter_location (
  id             int8 PRIMARY KEY,
  country_id     int4,
  country_name   varchar,
  continent_id   int4,
  continent_name varchar
);

CREATE TABLE IF NOT EXISTS webmap.organization_location (
  id             int8 PRIMARY KEY,
  country_id     int4,
  country_name   varchar,
  continent_id   int4,
  continent_name varchar
);

CREATE TABLE IF NOT EXISTS webmap.species_stat (
  species_id               int4,
  planter_id               int8,
  planting_organization_id int8
);

-- Key-value config (prod-only DDL; shape from query-api readers + airflow writers).
CREATE TABLE IF NOT EXISTS webmap.config (
  id     serial PRIMARY KEY,
  name   varchar NOT NULL,
  data   jsonb,
  ref_id varchar
);

-- Raw capture sink: the real DDL from the webmap-query-service-consumer migration.
CREATE TABLE IF NOT EXISTS webmap.raw_capture_feature (
  id                  uuid PRIMARY KEY,
  lat                 numeric NOT NULL,
  lon                 numeric NOT NULL,
  location            geometry(POINT, 4326) NOT NULL,
  field_user_id       int8 NOT NULL,
  field_username      varchar NOT NULL,
  device_identifier   varchar,
  attributes          jsonb,
  tracking_session_id uuid,
  map                 jsonb,
  created_at          timestamptz NOT NULL,
  updated_at          timestamptz NOT NULL
);
SQL
log "webmap schema ready"
