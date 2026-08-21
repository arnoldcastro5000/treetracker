#!/usr/bin/env bash
# post hook (step 2 of 2, after keycloak-client.sh): seed the shared BROWSER-FLOW fixtures the three
# wallet maps need (deeper-wallet-flows, pending-transfer-accept, wallet-trust-management). Idempotent.
#
# Seeds THREE realm users A/B/C and their wallets, with wallet.id == the Keycloak `sub` (identity
# decision: the wallet-api LOCAL JWKS branch sets req.wallet_id = decoded.sub). Keycloak 26 IGNORES a
# client-supplied user id (probed live: create 201 but a fresh UUID is assigned), so this hook CREATES
# each user, READS BACK its sub, and adopts the sub as the wallet id. Tokens on A (send-loop) and on C
# (bumped: the seeded pending transfer + the trust-payoff send). Trust seeded ONLY A -> B (send,
# trusted) so A -> B auto-completes while C -> B stays untrusted (lands pending).
#
# NOT seeded here (deferred to the service slice, which needs a RUNNING wallet-api): the post-up
# authenticated `POST /transfers` C -> B that creates the pending transfer, and the trust-payoff send.
# This hook only lays the wallets/tokens/trust the API and the browser build on.
#
# Talks to Keycloak over a short-lived port-forward (mirrors keycloak-client.sh) and to Postgres via
# the shared start_pf/stop_pf (mirrors migrate.sh). JSON via node (a hard orchestrator dependency).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)/orchestrator-lib.sh"

log "wallet-app seed: users A/B/C (+wallets, tokens, trust A->B) in realm '$KEYCLOAK_REALM' / $WALLET_APP_DB"

# ── Keycloak: ensure the three users, capture each sub ──────────────────────────
pkill -f "port-forward svc/keycloak" 2>/dev/null || true; sleep 1
k -n keycloak port-forward svc/keycloak 18080:8080 >/tmp/kc-seed-pf.log 2>&1 &
KC_PF=$!
trap 'kill "$KC_PF" 2>/dev/null || true; stop_pf' EXIT
KC=http://127.0.0.1:18080

jn() { node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")||"null");process.stdout.write(String(('"$1"')??""))' 2>/dev/null; }

TOK=""
for i in $(seq 1 30); do
  TOK=$(curl -sf -m5 -d client_id=admin-cli -d "username=$KEYCLOAK_ADMIN" -d "password=$KEYCLOAK_ADMIN_PASSWORD" \
        -d grant_type=password "$KC/realms/master/protocol/openid-connect/token" 2>/dev/null | jn 'd&&d.access_token' || true)
  [ -n "$TOK" ] && break; sleep 2
done
[ -n "$TOK" ] || die "could not get a Keycloak master admin token (is keycloak up?)"
AUTH=(-H "Authorization: Bearer $TOK")

# ensure_user <email> <displayName> -> echoes the user's sub (id). Idempotent. Keycloak 26's declarative
# user profile requires BOTH firstName and lastName, else a direct grant fails "Account is not fully set
# up" (verified live), so the profile is ALWAYS ensured (PUT), not only on create - this self-heals a
# user made by an earlier incomplete run. Then a known non-temporary password is (re)set.
ensure_user() {
  local email="$1" name="$2" id profile pw
  id=$(curl -sf -m10 "${AUTH[@]}" "$KC/admin/realms/$KEYCLOAK_REALM/users?email=$email&exact=true" | jn 'd&&d[0]&&d[0].id')
  profile=$(node -e 'const[e,n]=process.argv.slice(1);process.stdout.write(JSON.stringify({username:e,email:e,enabled:true,emailVerified:true,firstName:n,lastName:"Wallet"}))' "$email" "$name")
  if [ -z "$id" ]; then
    curl -sf -m10 "${AUTH[@]}" -H "Content-Type: application/json" -X POST -d "$profile" \
      "$KC/admin/realms/$KEYCLOAK_REALM/users" >/dev/null || die "user create failed: $email"
    id=$(curl -sf -m10 "${AUTH[@]}" "$KC/admin/realms/$KEYCLOAK_REALM/users?email=$email&exact=true" | jn 'd&&d[0]&&d[0].id')
    [ -n "$id" ] || die "user created but lookup returned no id: $email"
    info "created user $email ($id)" >&2
  else
    curl -sf -m10 "${AUTH[@]}" -H "Content-Type: application/json" -X PUT -d "$profile" \
      "$KC/admin/realms/$KEYCLOAK_REALM/users/$id" >/dev/null || die "user profile update failed: $email"
    info "user $email already present ($id) -> profile ensured" >&2
  fi
  pw=$(node -e 'process.stdout.write(JSON.stringify({type:"password",value:process.argv[1],temporary:false}))' "$WALLET_SEED_PASSWORD")
  curl -sf -m10 "${AUTH[@]}" -H "Content-Type: application/json" -X PUT -d "$pw" \
    "$KC/admin/realms/$KEYCLOAK_REALM/users/$id/reset-password" >/dev/null || die "set password failed: $email"
  echo "$id"
}

A_SUB=$(ensure_user "$WALLET_SEED_A_EMAIL" "$WALLET_SEED_A_NAME")
B_SUB=$(ensure_user "$WALLET_SEED_B_EMAIL" "$WALLET_SEED_B_NAME")
C_SUB=$(ensure_user "$WALLET_SEED_C_EMAIL" "$WALLET_SEED_C_NAME")
[ -n "$A_SUB" ] && [ -n "$B_SUB" ] && [ -n "$C_SUB" ] || die "missing a seeded user sub (A=$A_SUB B=$B_SUB C=$C_SUB)"
kill "$KC_PF" 2>/dev/null || true

# ── Postgres: wallets (id == sub) + tokens + trust A->B (idempotent) ────────────
start_pf
q() { PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -d "$WALLET_APP_DB" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Guard: wallet.name is UNIQUE. If a target name already exists under a DIFFERENT id, the Keycloak subs
# have changed under a stale DB (e.g. the realm users were recreated but the DB kept). Insert-by-id
# would then hit the UNIQUE(name) index with a cryptic error, so fail early with an actionable one.
collide=$(q "SELECT string_agg(name, ', ') FROM wallet.wallet
  WHERE (name = '$WALLET_SEED_A_NAME' AND id <> '$A_SUB')
     OR (name = '$WALLET_SEED_B_NAME' AND id <> '$B_SUB')
     OR (name = '$WALLET_SEED_C_NAME' AND id <> '$C_SUB')")
[ -z "$collide" ] || die "wallet name(s) [$collide] already exist under a different id (Keycloak subs changed); reset the $WALLET_APP_DB DB (./k3s/down.sh) then re-run"

PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -d "$WALLET_APP_DB" -v ON_ERROR_STOP=1 \
  -v aid="$A_SUB" -v bid="$B_SUB" -v cid="$C_SUB" \
  -v aname="$WALLET_SEED_A_NAME" -v bname="$WALLET_SEED_B_NAME" -v cname="$WALLET_SEED_C_NAME" \
  -v atok="$WALLET_SEED_A_TOKENS" -v ctok="$WALLET_SEED_C_TOKENS" >/dev/null <<'SQL' || die "wallet fixture seed failed"
-- wallets: id adopts the Keycloak sub; name is UNIQUE. Idempotent by id.
INSERT INTO wallet.wallet (id, name) SELECT :'aid', :'aname' WHERE NOT EXISTS (SELECT 1 FROM wallet.wallet WHERE id = :'aid');
INSERT INTO wallet.wallet (id, name) SELECT :'bid', :'bname' WHERE NOT EXISTS (SELECT 1 FROM wallet.wallet WHERE id = :'bid');
INSERT INTO wallet.wallet (id, name) SELECT :'cid', :'cname' WHERE NOT EXISTS (SELECT 1 FROM wallet.wallet WHERE id = :'cid');

-- tokens: capture_id references nothing (unique), wallet_id = owner. TOP UP to the target count so a
-- re-run adds only the difference (idempotent when already at target; supports bumping the count).
INSERT INTO wallet.token (capture_id, wallet_id)
  SELECT gen_random_uuid(), :'aid'
  FROM generate_series(1, GREATEST(0, :atok - (SELECT count(*) FROM wallet.token WHERE wallet_id = :'aid')));
INSERT INTO wallet.token (capture_id, wallet_id)
  SELECT gen_random_uuid(), :'cid'
  FROM generate_series(1, GREATEST(0, :ctok - (SELECT count(*) FROM wallet.token WHERE wallet_id = :'cid')));

-- trust A -> B: send, trusted (so a send A -> B auto-completes). active defaults true. Idempotent.
INSERT INTO wallet.wallet_trust (actor_wallet_id, target_wallet_id, originator_wallet_id, type, request_type, state)
  SELECT :'aid', :'bid', :'aid',
         'send'::wallet.entity_trust_type, 'send'::wallet.entity_trust_request_type, 'trusted'::wallet.entity_trust_state_type
  WHERE NOT EXISTS (
    SELECT 1 FROM wallet.wallet_trust
    WHERE actor_wallet_id = :'aid' AND target_wallet_id = :'bid' AND request_type = 'send'::wallet.entity_trust_request_type);
SQL

# ── Verify (hard assertions) ────────────────────────────────────────────────────
[ "$(q "SELECT count(*) FROM wallet.wallet WHERE id IN ('$A_SUB','$B_SUB','$C_SUB')")" = 3 ] || die "expected 3 seeded wallets"
[ "$(q "SELECT count(*) FROM wallet.token WHERE wallet_id='$A_SUB'")" = "$WALLET_SEED_A_TOKENS" ] || die "A token count != $WALLET_SEED_A_TOKENS"
[ "$(q "SELECT count(*) FROM wallet.token WHERE wallet_id='$C_SUB'")" = "$WALLET_SEED_C_TOKENS" ] || die "C token count != $WALLET_SEED_C_TOKENS"
[ "$(q "SELECT count(*) FROM wallet.token WHERE wallet_id='$B_SUB'")" = 0 ] || die "B should own no tokens"
[ "$(q "SELECT count(*) FROM wallet.wallet_trust WHERE actor_wallet_id='$A_SUB' AND target_wallet_id='$B_SUB' AND request_type='send' AND state='trusted'")" = 1 ] || die "A->B send-trust (trusted) missing"
[ "$(q "SELECT count(*) FROM wallet.wallet_trust WHERE actor_wallet_id='$C_SUB' AND target_wallet_id='$B_SUB' AND state='trusted'")" = 0 ] || die "C->B must stay untrusted"
stop_pf

# ── Verify identity loop: each user's password-grant token carries sub == wallet.id ─────────────────
pkill -f "port-forward svc/keycloak" 2>/dev/null || true; sleep 1
k -n keycloak port-forward svc/keycloak 18080:8080 >/tmp/kc-seed-pf2.log 2>&1 &
KC_PF=$!
kc_ready=""
for i in $(seq 1 30); do
  curl -sf -m5 "$KC/realms/$KEYCLOAK_REALM/.well-known/openid-configuration" >/dev/null 2>&1 && { kc_ready=1; break; }
  sleep 1
done
[ -n "$kc_ready" ] || die "keycloak realm '$KEYCLOAK_REALM' not ready for the identity-loop verify"
sub_of() { # <email> -> the sub in a password-grant token via the wallet confidential client
  local email="$1" t
  t=$(curl -sf -m8 -d "client_id=$KEYCLOAK_WALLET_CLIENT_ID" -d "client_secret=$KEYCLOAK_WALLET_CLIENT_SECRET" \
        -d "username=$email" -d "password=$WALLET_SEED_PASSWORD" -d grant_type=password \
        "$KC/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" | jn 'd&&d.access_token')
  [ -n "$t" ] || return 1
  node -e 'const p=JSON.parse(Buffer.from(process.argv[1].split(".")[1],"base64url").toString());process.stdout.write(p.sub||"")' "$t"
}
for pair in "A:$WALLET_SEED_A_EMAIL:$A_SUB" "B:$WALLET_SEED_B_EMAIL:$B_SUB" "C:$WALLET_SEED_C_EMAIL:$C_SUB"; do
  who="${pair%%:*}"; rest="${pair#*:}"; email="${rest%%:*}"; want="${rest#*:}"
  got=$(sub_of "$email") || die "password grant failed for $who ($email)"
  [ "$got" = "$want" ] || die "identity mismatch for $who: token sub=$got but wallet.id=$want"
done
info "identity loop verified: A/B/C password-grant sub == wallet.id"
info "seed ready: A(${WALLET_SEED_A_TOKENS} tokens)->B trusted; C(${WALLET_SEED_C_TOKENS} tokens)->B untrusted; B owns 0"
