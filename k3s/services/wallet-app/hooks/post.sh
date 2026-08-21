#!/usr/bin/env bash
# post hook: three ordered steps. The adapter contract allows one post script, so this composes them.
#   1. keycloak-client.sh      - ensure the wallet-app confidential client + its service-account role.
#   2. seed-fixtures.sh        - seed the shared browser-flow fixtures (users A/B/C, wallets, tokens,
#                                trust A->B). Runs after Keycloak is up (it creates realm users).
#   3. seed-pending-transfer.sh - create the pending C->B transfer via the running wallet-api. Runs
#                                last: the POST phase is after waitFor, so wallet-api is up.
set -euo pipefail
d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$d/keycloak-client.sh"
"$d/seed-fixtures.sh"
"$d/seed-pending-transfer.sh"
