#!/usr/bin/env bash
# post hook: ensure the wallet-app's Keycloak confidential client (wallet-app decision 02) exists
# on the shared `treetracker` realm. Each subsystem owns its client via an idempotent hook, never a
# central realm file (identity decision 05). The client: confidential (dummy-literal secret), Direct
# Access Grants ON (password login), Service Accounts ON (client_credentials for the Admin API),
# Standard Flow OFF, no redirect URIs, service-account role realm-management:manage-users.
# Uses the Keycloak Admin REST API over a short-lived port-forward with the master bootstrap admin.
# JSON handling uses node (a hard orchestrator dependency, checked in preflight; matches seed-admin.sh).
set -euo pipefail
. "$(cd "$(dirname "$0")/../../../lib" && pwd)/orchestrator-lib.sh"

CID="$KEYCLOAK_WALLET_CLIENT_ID"
log "keycloak: ensure client '$CID' on realm '$KEYCLOAK_REALM'"
pkill -f "port-forward svc/keycloak" 2>/dev/null || true; sleep 1
k -n keycloak port-forward svc/keycloak 18080:8080 >/tmp/kc-client-pf.log 2>&1 &
pf=$!
trap 'kill "$pf" 2>/dev/null || true' EXIT
KC=http://127.0.0.1:18080

# jn <expr>: parse stdin JSON into `d`, print the JS expression (empty string for missing values).
jn() { node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")||"null");const v=('"$1"');process.stdout.write(v==null?"":String(v))' 2>/dev/null; }

# wait for the port-forward + admin token endpoint
TOK=""
for i in $(seq 1 30); do
  TOK=$(curl -sf -m5 -d client_id=admin-cli -d "username=$KEYCLOAK_ADMIN" -d "password=$KEYCLOAK_ADMIN_PASSWORD" \
        -d grant_type=password "$KC/realms/master/protocol/openid-connect/token" 2>/dev/null | jn 'd&&d.access_token' || true)
  [ -n "$TOK" ] && break; sleep 2
done
[ -n "$TOK" ] || die "could not get a Keycloak master admin token (is keycloak up?)"
AUTH=(-H "Authorization: Bearer $TOK")

# client representation (dummy-literal secret from config)
rep=$(node -e 'const[cid,sec]=process.argv.slice(1);process.stdout.write(JSON.stringify({clientId:cid,enabled:true,protocol:"openid-connect",publicClient:false,secret:sec,serviceAccountsEnabled:true,directAccessGrantsEnabled:true,standardFlowEnabled:false,redirectUris:[]}))' "$CID" "$KEYCLOAK_WALLET_CLIENT_SECRET")

# create if absent, else update (idempotent)
uuid=$(curl -sf -m10 "${AUTH[@]}" "$KC/admin/realms/$KEYCLOAK_REALM/clients?clientId=$CID" | jn 'd&&d[0]&&d[0].id')
if [ -z "$uuid" ]; then
  curl -sf -m10 "${AUTH[@]}" -H "Content-Type: application/json" -X POST -d "$rep" \
    "$KC/admin/realms/$KEYCLOAK_REALM/clients" >/dev/null || die "client create failed"
  uuid=$(curl -sf -m10 "${AUTH[@]}" "$KC/admin/realms/$KEYCLOAK_REALM/clients?clientId=$CID" | jn 'd&&d[0]&&d[0].id')
  [ -n "$uuid" ] || die "client created but lookup returned no id for $CID"
  info "created client $CID ($uuid)"
else
  curl -sf -m10 "${AUTH[@]}" -H "Content-Type: application/json" -X PUT -d "$rep" \
    "$KC/admin/realms/$KEYCLOAK_REALM/clients/$uuid" >/dev/null || die "client update failed"
  info "client $CID already present ($uuid) -> ensured settings"
fi

# assign the service-account user the realm-management:manage-users role (for the Admin user-create API)
sa=$(curl -sf -m10 "${AUTH[@]}" "$KC/admin/realms/$KEYCLOAK_REALM/clients/$uuid/service-account-user" | jn 'd&&d.id')
[ -n "$sa" ] || die "no service-account user for $CID"
rm=$(curl -sf -m10 "${AUTH[@]}" "$KC/admin/realms/$KEYCLOAK_REALM/clients?clientId=realm-management" | jn 'd&&d[0]&&d[0].id')
[ -n "$rm" ] || die "realm-management client not found"
role=$(curl -sf -m10 "${AUTH[@]}" "$KC/admin/realms/$KEYCLOAK_REALM/clients/$rm/roles/manage-users")
# guard: an empty/failed role fetch would POST '[]' (a silent no-op that still returns 200)
[ -n "$(printf '%s' "$role" | jn 'd&&d.id')" ] || die "could not read the realm-management:manage-users role"
curl -sf -m10 "${AUTH[@]}" -H "Content-Type: application/json" -X POST -d "[$role]" \
  "$KC/admin/realms/$KEYCLOAK_REALM/users/$sa/role-mappings/clients/$rm" >/dev/null || die "role assignment failed"
info "service account has realm-management:manage-users"

# verify: password grant (login path) + client_credentials (service-account path) both work
pw=$(curl -sf -m5 -d "client_id=$CID" -d "client_secret=$KEYCLOAK_WALLET_CLIENT_SECRET" \
     -d "username=$KEYCLOAK_TEST_USER" -d "password=$KEYCLOAK_TEST_PASSWORD" -d grant_type=password \
     "$KC/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" | jn 'd&&d.access_token?"ok":""')
[ "$pw" = ok ] || die "password grant via $CID failed (test user login)"
cc=$(curl -sf -m5 -d "client_id=$CID" -d "client_secret=$KEYCLOAK_WALLET_CLIENT_SECRET" -d grant_type=client_credentials \
     "$KC/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" | jn 'd&&d.access_token?"ok":""')
[ "$cc" = ok ] || die "client_credentials grant via $CID failed (service account)"
info "client '$CID' ready: password grant + client_credentials both issue tokens"
