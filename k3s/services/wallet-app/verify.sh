#!/usr/bin/env bash
# verify hook (hard gate): prove the wallet-api service works end to end against the seeded data.
# Mints a real Keycloak access token for the seeded user B (wallet client, password grant, over a
# short-lived Keycloak port-forward - the gateway /keycloak route only serves GET), then calls
# GET /wallet/v2/wallets with that Bearer + the seeded `treetracker-api-key` through the gateway.
# Asserts 200 and that the caller's own wallet (id == the token `sub`, set by the seed) is in the
# response - exercising the LOCAL Keycloak-JWKS auth path (sub -> wallet_id), the api-key gate, the
# wallet_app DB (schema wallet), and the /wallet/v2/ gateway Mapping in one shot. Also checks that
# dropping either credential is rejected (both auth gates are live).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/orchestrator-lib.sh"

GW="${GATEWAY_URL:-http://localhost:8088}"
jn() { node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")||"null");process.stdout.write(String(('"$1"')??""))' 2>/dev/null; }

log "wallet-app verify: Keycloak-bearer + api-key GET /wallet/v2/wallets"

pkill -f "port-forward svc/keycloak" 2>/dev/null || true; sleep 1
k -n keycloak port-forward svc/keycloak 18080:8080 >/tmp/kc-verify-pf.log 2>&1 &
KC_PF=$!
trap 'kill "$KC_PF" 2>/dev/null || true' EXIT
KC=http://127.0.0.1:18080
for i in $(seq 1 30); do
  curl -sf -m5 "$KC/realms/$KEYCLOAK_REALM/.well-known/openid-configuration" >/dev/null 2>&1 && break; sleep 1
done
TOK=$(curl -sf -m10 \
  -d "client_id=$KEYCLOAK_WALLET_CLIENT_ID" -d "client_secret=$KEYCLOAK_WALLET_CLIENT_SECRET" \
  -d "username=$WALLET_SEED_B_EMAIL" -d "password=$WALLET_SEED_PASSWORD" -d grant_type=password \
  "$KC/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" | jn 'd&&d.access_token')
[ -n "$TOK" ] || die "could not mint a Keycloak token for $WALLET_SEED_B_EMAIL"
SUB=$(node -e 'const p=JSON.parse(Buffer.from(process.argv[1].split(".")[1],"base64url").toString());process.stdout.write(p.sub||"")' "$TOK")
[ -n "$SUB" ] || die "minted token has no sub"

BODY=$(mktemp)
CODE=$(curl -s -m10 -o "$BODY" -w '%{http_code}' \
  -H "Authorization: Bearer $TOK" -H "treetracker-api-key: $WALLET_API_KEY" \
  "$GW/wallet/v2/wallets")
[ "$CODE" = 200 ] || die "GET /wallet/v2/wallets -> $CODE (expected 200); body: $(head -c 400 "$BODY")"
grep -q "$SUB" "$BODY" || die "response has no wallet with id == token sub ($SUB); body: $(head -c 400 "$BODY")"
info "GET /wallet/v2/wallets -> 200; caller wallet ($SUB, '$WALLET_SEED_B_NAME') present"

# auth gates: dropping the api-key OR the bearer must NOT return 200
NOKEY=$(curl -s -m10 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" "$GW/wallet/v2/wallets")
[ "$NOKEY" != 200 ] || die "missing treetracker-api-key still returned 200 (api-key gate broken)"
NOBEARER=$(curl -s -m10 -o /dev/null -w '%{http_code}' -H "treetracker-api-key: $WALLET_API_KEY" "$GW/wallet/v2/wallets")
[ "$NOBEARER" != 200 ] || die "missing Bearer still returned 200 (jwt gate broken)"
rm -f "$BODY"
info "auth gates enforced (api-key -> $NOKEY, bearer -> $NOBEARER without credentials)"
info "wallet-api service verify GREEN"

# --- apps/user (the NestJS user-api) through the gateway /user-api/ Mapping ---
log "wallet-app verify: apps/user healthz + login (Keycloak password grant server-side)"
HZ=$(curl -s -m10 -o /dev/null -w '%{http_code}' "$GW/user-api/healthz")
[ "$HZ" = 200 ] || die "GET /user-api/healthz -> $HZ (expected 200)"
LBODY=$(mktemp)
LCODE=$(curl -s -m15 -o "$LBODY" -w '%{http_code}' -X POST "$GW/user-api/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$WALLET_SEED_B_EMAIL\",\"password\":\"$WALLET_SEED_PASSWORD\"}")
[ "$LCODE" = 200 ] || die "POST /user-api/login -> $LCODE (expected 200); body: $(head -c 400 "$LBODY")"
UTOK=$(jn 'd&&d.access_token' <"$LBODY")
[ -n "$UTOK" ] || die "login returned no access_token; body: $(head -c 400 "$LBODY")"
# a wrong password must NOT return 200 (the login path really reaches Keycloak)
BADPW=$(curl -s -m15 -o /dev/null -w '%{http_code}' -X POST "$GW/user-api/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$WALLET_SEED_B_EMAIL\",\"password\":\"definitely-wrong\"}")
[ "$BADPW" != 200 ] || die "login with a wrong password still returned 200 (login not really authenticating)"
rm -f "$LBODY"
info "apps/user verify GREEN (healthz 200; login -> access_token; wrong password -> $BADPW)"
