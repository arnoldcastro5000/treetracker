#!/usr/bin/env bash
# post hook: two ordered steps. The adapter contract allows one post script, so this composes them.
#   1. keycloak-client.sh - ensure the wallet-app confidential client + its service-account role.
#   2. seed-fixtures.sh    - seed the shared browser-flow fixtures (users A/B/C, wallets, tokens,
#                            trust A->B). Runs second: it creates realm users, so Keycloak must be up.
set -euo pipefail
d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$d/keycloak-client.sh"
"$d/seed-fixtures.sh"
