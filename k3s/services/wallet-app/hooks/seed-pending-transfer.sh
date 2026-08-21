#!/usr/bin/env bash
# post hook (step 3 of 3, after seed-fixtures.sh): create the pending C -> B transfer the
# pending-transfer-accept + wallet-trust maps need. This is deliberately done via the REAL running
# wallet-api (not hand-seeded SQL): authenticate as C, POST /transfers C -> B with NO trust, so the
# transfer lands `pending` (exercising the verified create path). B accepts/declines it in the browser
# (a later slice). Runs in the POST phase, AFTER waitFor, so wallet-api is up and reachable.
# Idempotent: skips if a pending C -> B transfer already exists.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)/orchestrator-lib.sh"

GW="${GATEWAY_URL:-http://localhost:8088}"
jn() { node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")||"null");process.stdout.write(String(('"$1"')??""))' 2>/dev/null; }
q() { PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -d "$WALLET_APP_DB" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

log "wallet-app seed: pending transfer C -> B (no trust -> pending) via the running wallet-api"

# wallet ids by name (the seed set wallet.id == the Keycloak sub)
trap stop_pf EXIT   # install immediately: no leak window if interrupted between start_pf and the token pf
start_pf
C_ID=$(q "SELECT id FROM wallet.wallet WHERE name = '$WALLET_SEED_C_NAME'")
B_ID=$(q "SELECT id FROM wallet.wallet WHERE name = '$WALLET_SEED_B_NAME'")
[ -n "$C_ID" ] && [ -n "$B_ID" ] || die "seeded wallets missing (C=$C_ID B=$B_ID); run seed-fixtures first"
# NUMERIC guard: an empty result (a failed count query) must NOT read as "already present" and skip -
# default to 0 so a query error makes us PROCEED (a re-check at the end is the real gate), never false-green.
EXISTING=$(q "SELECT count(*) FROM wallet.transfer WHERE source_wallet_id='$C_ID' AND destination_wallet_id='$B_ID' AND state='pending'")
if [ "${EXISTING:-0}" -gt 0 ] 2>/dev/null; then
  info "pending C -> B transfer already present -> skip"
  exit 0
fi
stop_pf

# mint C's access token over a short-lived Keycloak port-forward (the gateway /keycloak route is GET-only)
pkill -f "port-forward svc/keycloak" 2>/dev/null || true; sleep 1
k -n keycloak port-forward svc/keycloak 18080:8080 >/tmp/kc-pending-pf.log 2>&1 &
KC_PF=$!
trap 'kill "$KC_PF" 2>/dev/null || true; stop_pf' EXIT
KC=http://127.0.0.1:18080
for i in $(seq 1 30); do
  curl -sf -m5 "$KC/realms/$KEYCLOAK_REALM/.well-known/openid-configuration" >/dev/null 2>&1 && break; sleep 1
done
TOK=$(curl -sf -m10 \
  -d "client_id=$KEYCLOAK_WALLET_CLIENT_ID" -d "client_secret=$KEYCLOAK_WALLET_CLIENT_SECRET" \
  -d "username=$WALLET_SEED_C_EMAIL" -d "password=$WALLET_SEED_PASSWORD" -d grant_type=password \
  "$KC/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" | jn 'd&&d.access_token')
[ -n "$TOK" ] || die "could not mint a Keycloak token for $WALLET_SEED_C_EMAIL"
kill "$KC_PF" 2>/dev/null || true

# Wait for the /wallet/v2/ gateway route to go live before the (non-idempotent) POST: Emissary
# reconciles the Mapping asynchronously, so just after the rollout the route can briefly 503/000. A
# 401/200 means the Mapping + wallet-api are up and the auth gate answers - then one clean POST.
for i in $(seq 1 30); do
  rc=$(curl -s -m5 -o /dev/null -w '%{http_code}' "$GW/wallet/v2/wallets")
  case "$rc" in 401|200) break ;; esac; sleep 1
done

# POST /transfers C -> B (bundle form, no trust -> pending) through the gateway
BODY=$(node -e 'const[s,r,n]=process.argv.slice(1);process.stdout.write(JSON.stringify({sender_wallet:s,receiver_wallet:r,claim:false,bundle:{bundle_size:Number(n)}}))' "$C_ID" "$B_ID" "$WALLET_SEED_PENDING_AMOUNT")
OUT=$(mktemp)
CODE=$(curl -s -m15 -o "$OUT" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOK" -H "treetracker-api-key: $WALLET_API_KEY" -H 'Content-Type: application/json' \
  -d "$BODY" "$GW/wallet/v2/transfers")
STATE=$(jn 'd&&d.state' < "$OUT")
# wallet-api returns 202 Accepted for a pending transfer (200/201 on other paths); anything else is a
# real failure, surfaced as a warning and then re-checked hard against the DB below.
case "$CODE" in 200|201|202) ;; *) warn "POST /transfers -> $CODE (state '$STATE'); body: $(head -c 300 "$OUT")" ;; esac
rm -f "$OUT"

# confirm the pending row exists (source C, dest B, state pending)
start_pf
CNT=$(q "SELECT count(*) FROM wallet.transfer WHERE source_wallet_id='$C_ID' AND destination_wallet_id='$B_ID' AND state='pending'")
[ "${CNT:-0}" -ge 1 ] 2>/dev/null || die "no pending C -> B transfer after POST (api state '$STATE', code $CODE)"
# NOTE: a bundle pending transfer reserves tokens at ACCEPT, not at create, so none of C's tokens are
# transfer_pending yet; C keeps all $WALLET_SEED_C_TOKENS spendable (enough for the later trust-payoff send).
info "pending C -> B transfer created (bundle $WALLET_SEED_PENDING_AMOUNT, api state '$STATE')"
