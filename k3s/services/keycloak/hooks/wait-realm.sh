#!/usr/bin/env bash
# post hook: gate on the treetracker realm being imported and serving OIDC discovery, so a
# subsystem hook (which creates its own confidential client via kcadm) can rely on it existing.
# The waitFor rollout only proves the pod is Ready; this proves the realm actually imported.
set -euo pipefail
. "$(cd "$(dirname "$0")/../../../lib" && pwd)/orchestrator-lib.sh"

log "keycloak: waiting for realm '$KEYCLOAK_REALM' OIDC discovery"
# Port-forward the in-cluster service to the host (the official image is minimal and may lack curl,
# so probe from the host rather than exec-ing into the pod). Use an uncommon local port.
pkill -f "port-forward svc/keycloak" 2>/dev/null || true; sleep 1
k -n keycloak port-forward svc/keycloak 18080:8080 >/tmp/kc-pf.log 2>&1 &
pf=$!
trap 'kill "$pf" 2>/dev/null || true' EXIT
url="http://127.0.0.1:18080/realms/$KEYCLOAK_REALM/.well-known/openid-configuration"
for i in $(seq 1 60); do
  curl -sf -m 5 "$url" >/dev/null 2>&1 && { info "realm '$KEYCLOAK_REALM' OIDC discovery OK"; exit 0; }
  sleep 2
done
die "keycloak realm '$KEYCLOAK_REALM' never served OIDC discovery ($url) - check: kubectl -n keycloak logs deploy/keycloak"
