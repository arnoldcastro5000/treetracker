#!/usr/bin/env bash
# post hook: block until the shared Postgres accepts connections (pg_isready), so dependent
# adapters can create databases and run migrations immediately.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)/orchestrator-lib.sh"
wait_pg_ready
info "postgres accepting connections"
