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
trap 'kill "$KC_PF" 2>/dev/null || true; rm -f "${WOUT:-}" "${BODY:-}" "${LBODY:-}" "${WBODY:-}" 2>/dev/null || true' EXIT
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
# register path reachability (idempotent): POST an already-seeded user, so no new user is created;
# assert the /user-api/register route reaches apps/user through the gateway (not a gateway 404/5xx).
RCODE=$(curl -s -m15 -o /dev/null -w '%{http_code}' -X POST "$GW/user-api/register" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$WALLET_SEED_B_EMAIL\",\"email\":\"$WALLET_SEED_B_EMAIL\",\"password\":\"$WALLET_SEED_PASSWORD\"}")
case "$RCODE" in
  000|404|501|502|503|504) die "POST /user-api/register -> $RCODE (register route not reachable via the gateway)";;
esac
info "apps/user verify GREEN (healthz 200; login -> access_token; wrong password -> $BADPW; register route reachable -> $RCODE)"

# --- apps/web (the Next 14 static SPA) through the gateway /wallet Mapping ---
log "wallet-app verify: apps/web static SPA at /wallet"
WBODY=$(mktemp)
# the SPA entry and the login page must both serve the export shell (proves basePath routing + nginx)
WROOT=$(curl -s -m10 -o "$WBODY" -w '%{http_code}' "$GW/wallet/login")
[ "$WROOT" = 200 ] || die "GET /wallet/login -> $WROOT (expected 200); body: $(head -c 300 "$WBODY")"
grep -qi "<!doctype html" "$WBODY" || die "/wallet/login did not serve an HTML document; body: $(head -c 300 "$WBODY")"
# a hashed _next asset referenced by the page must load through the /wallet asset prefix
ASSET=$(grep -oE "/wallet/_next/[^\"']+\.js" "$WBODY" | head -1)
[ -n "$ASSET" ] || die "/wallet/login references no /wallet/_next asset (basePath not applied)"
ACODE=$(curl -s -m10 -o /dev/null -w '%{http_code}' "$GW$ASSET")
[ "$ACODE" = 200 ] || die "GET $ASSET -> $ACODE (expected 200); _next asset serving broken"
rm -f "$WBODY"
info "apps/web verify GREEN (/wallet/login 200 HTML; /wallet/_next asset 200)"

# --- wallet token FLOWS through the real API (send auto-complete, pending accept, trust payoff) ---
# Proves the whole browser loop end to end, not just that the services stand up. Uses /user-api/login
# to mint the same access tokens the browser uses (they carry the wallet id in `sub`). This MOVES real
# tokens: each run adds a few tokens to B and drains ~3 from C. It is SELF-CLEANING for trust (it revokes
# the C->B trust it grants) and self-healing (a clean-slate decline recovers a run interrupted mid-trust).
# It ASSUMES a fresh seed: `up.sh wallet-app` re-seeds first (resets B to 0, tops A/C back to their
# target, clears the C->B trust), so run it that way rather than `up.sh verify` repeatedly, which would
# drain C without a refill.
log "wallet-app verify: token flows (send auto-complete, pending accept, trust payoff)"

# The helpers end with `|| true` so a curl TRANSPORT failure yields an empty result (caught by the
# callers' guards / non-201 checks with an actionable message) instead of tripping `set -e` mid-capture.
login() {
  curl -s -m15 -X POST "$GW/user-api/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"$WALLET_SEED_PASSWORD\"}" | jn 'd&&d.access_token' || true
}
sub_of() {
  node -e 'const p=JSON.parse(Buffer.from(process.argv[1].split(".")[1],"base64url").toString());process.stdout.write(p.sub||"")' "$1" || true
}
WOUT=$(mktemp)
# $1 token  $2 method  $3 path (under /wallet/v2)  $4 body (optional); writes body to $WOUT, echoes code
wapi() {
  local args=(-s -m15 -o "$WOUT" -w '%{http_code}' -X "$2" \
    -H "Authorization: Bearer $1" -H "treetracker-api-key: $WALLET_API_KEY" -H 'Content-Type: application/json')
  [ -n "${4:-}" ] && args+=(-d "$4")
  curl "${args[@]}" "$GW/wallet/v2$3" || true
}
# $1 token  $2 wallet name -> echoes tokens_in_wallet (empty if absent)
balance() {
  curl -s -m15 -H "Authorization: Bearer $1" -H "treetracker-api-key: $WALLET_API_KEY" \
    "$GW/wallet/v2/wallets?limit=1000" \
    | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")||"{}");const w=(d.wallets||[]).find(w=>w.name===process.argv[1]);process.stdout.write(w?String(w.tokens_in_wallet):"")' "$2" || true
}

ATOK=$(login "$WALLET_SEED_A_EMAIL"); [ -n "$ATOK" ] || die "flows: login A ($WALLET_SEED_A_EMAIL) failed"
BTOK=$(login "$WALLET_SEED_B_EMAIL"); [ -n "$BTOK" ] || die "flows: login B ($WALLET_SEED_B_EMAIL) failed"
CTOK=$(login "$WALLET_SEED_C_EMAIL"); [ -n "$CTOK" ] || die "flows: login C ($WALLET_SEED_C_EMAIL) failed"
AID=$(sub_of "$ATOK"); BID=$(sub_of "$BTOK"); CID=$(sub_of "$CTOK")
[ -n "$AID" ] && [ -n "$BID" ] && [ -n "$CID" ] || die "flows: could not read wallet ids from tokens"

# Clean slate (self-heal): a run interrupted mid-trust can leave an active C->B send-trust. Decline any
# requested/trusted C->B row up front so C->B starts UNTRUSTED, which the pending-send step below relies
# on. (up.sh already clears this in the seed; this covers a standalone `up.sh verify` re-run.)
wapi "$CTOK" GET "/trust_relationships?limit=200" >/dev/null
LEFT=$(node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")||"{}");const r=(d.trust_relationships||[]).find(t=>t.actor_wallet_id===process.argv[1]&&t.target_wallet_id===process.argv[2]&&t.request_type==="send"&&(t.state==="requested"||t.state==="trusted"));process.stdout.write(r?r.id:"")' "$CID" "$BID" <"$WOUT")
[ -n "$LEFT" ] && wapi "$BTOK" POST "/trust_relationships/$LEFT/decline" "{}" >/dev/null || true

# 1. a send to a TRUSTED recipient (A->B, seeded trust) auto-completes and raises B's balance
B0=$(balance "$BTOK" "$WALLET_SEED_B_NAME"); [ -n "$B0" ] || die "flows: could not read B balance"
CODE=$(wapi "$ATOK" POST /transfers "{\"sender_wallet\":\"$AID\",\"receiver_wallet\":\"$BID\",\"claim\":false,\"bundle\":{\"bundle_size\":1}}")
[ "$CODE" = 201 ] || die "flows: A->B trusted send -> $CODE (expected 201); $(head -c 300 "$WOUT")"
[ "$(jn 'd&&d.state' <"$WOUT")" = completed ] || die "flows: A->B send not completed; $(head -c 300 "$WOUT")"
B1=$(balance "$BTOK" "$WALLET_SEED_B_NAME")
[ "$B1" = "$((B0 + 1))" ] || die "flows: A->B send did not raise B ($B0 -> $B1, expected +1)"
info "send auto-completes on trust: A->B 201 completed; B $B0 -> $B1"

# 2. a send to an UNTRUSTED recipient (C->B) lands pending; B sees it and accepting moves the tokens
CODE=$(wapi "$CTOK" POST /transfers "{\"sender_wallet\":\"$CID\",\"receiver_wallet\":\"$BID\",\"claim\":false,\"bundle\":{\"bundle_size\":2}}")
[ "$CODE" = 202 ] || die "flows: C->B untrusted send -> $CODE (expected 202 pending); $(head -c 300 "$WOUT")"
PID=$(jn 'd&&d.id' <"$WOUT"); [ -n "$PID" ] || die "flows: pending transfer has no id"
wapi "$BTOK" GET "/transfers?state=pending&limit=100" >/dev/null
grep -q "$PID" "$WOUT" || die "flows: B pending list is missing the new transfer $PID"
B2=$(balance "$BTOK" "$WALLET_SEED_B_NAME")
CODE=$(wapi "$BTOK" POST "/transfers/$PID/accept" "{}")
[ "$CODE" = 200 ] || die "flows: B accept pending -> $CODE (expected 200); $(head -c 300 "$WOUT")"
B3=$(balance "$BTOK" "$WALLET_SEED_B_NAME")
[ "$B3" = "$((B2 + 2))" ] || die "flows: accept did not raise B ($B2 -> $B3, expected +2)"
info "pending accept moves tokens: C->B 202 pending; B accept 200; B $B2 -> $B3"

# 3. trust payoff: C requests a send-trust, B accepts, a fresh C->B send now COMPLETES (was pending).
#    Self-cleaning: B then declines the trust so C->B goes back to untrusted (keeps the seed premise).
CODE=$(wapi "$CTOK" POST /trust_relationships "{\"trust_request_type\":\"send\",\"requestee_wallet\":\"$WALLET_SEED_B_NAME\"}")
[ "$CODE" = 201 ] || die "flows: C request trust -> $CODE (expected 201); $(head -c 300 "$WOUT")"
TID=$(jn 'd&&d.id' <"$WOUT")
[ -n "$TID" ] || die "flows: trust request returned no id; $(head -c 300 "$WOUT")"
CODE=$(wapi "$BTOK" POST "/trust_relationships/$TID/accept" "{}")
[ "$CODE" = 200 ] || die "flows: B accept trust -> $CODE (expected 200); $(head -c 300 "$WOUT")"
[ "$(jn 'd&&d.state' <"$WOUT")" = trusted ] || die "flows: trust accept not trusted; $(head -c 300 "$WOUT")"
B4=$(balance "$BTOK" "$WALLET_SEED_B_NAME")
CODE=$(wapi "$CTOK" POST /transfers "{\"sender_wallet\":\"$CID\",\"receiver_wallet\":\"$BID\",\"claim\":false,\"bundle\":{\"bundle_size\":1}}")
[ "$CODE" = 201 ] || die "flows: trust payoff C->B send -> $CODE (expected 201 completed, was pending); $(head -c 300 "$WOUT")"
[ "$(jn 'd&&d.state' <"$WOUT")" = completed ] || die "flows: payoff send not completed; $(head -c 300 "$WOUT")"
B5=$(balance "$BTOK" "$WALLET_SEED_B_NAME")
[ "$B5" = "$((B4 + 1))" ] || die "flows: payoff send did not raise B ($B4 -> $B5, expected +1)"
CODE=$(wapi "$BTOK" POST "/trust_relationships/$TID/decline" "{}")
[ "$CODE" = 200 ] || die "flows: cleanup decline trust -> $CODE (expected 200); C->B left trusted"
info "trust payoff: C requests, B accepts, C->B 201 completed (B $B4 -> $B5); trust revoked (C->B untrusted again)"
rm -f "$WOUT"
info "wallet flows verify GREEN (send auto-complete, pending accept, trust payoff)"
