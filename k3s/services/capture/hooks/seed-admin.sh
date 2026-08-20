#!/usr/bin/env bash
# post hook: seed the legacy admin_user for the /verify login (username/password +
# HMAC-SHA512(pw,salt)). Idempotent: replaces the previous seed row.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)/orchestrator-lib.sh"

user="$ADMIN_USER" pass="$ADMIN_PASSWORD" email="$ADMIN_USER@greenstand.org"
# pass/salt reach node as argv, never interpolated into the source, so a quote in ADMIN_PASSWORD
# cannot break the script or inject code.
salt=$(node -e "console.log(require('crypto').randomBytes(16).toString('hex'))")
hash=$(node -e "const c=require('crypto');console.log(c.createHmac('sha512',process.argv[1]).update(process.argv[2]).digest('hex'))" "$salt" "$pass")
POD=$(pg_pod); [ -n "$POD" ] || die "no postgres pod"
# user/hash/salt/email are passed as psql variables and quoted with :'name', so psql escapes them;
# a quote in ADMIN_USER/ADMIN_PASSWORD cannot inject SQL.
k -n data exec -i "$POD" -- psql -U postgres -d treetracker -v ON_ERROR_STOP=1 \
  -v user="$user" -v hash="$hash" -v salt="$salt" -v email="$email" >/dev/null <<'SQL' || die "admin user seed failed"
BEGIN;
DELETE FROM admin_user_role WHERE admin_user_id IN (SELECT id FROM admin_user WHERE user_name=:'user');
DELETE FROM admin_user WHERE user_name=:'user';
DELETE FROM admin_role WHERE role_name='Local Super';
WITH r AS (
  INSERT INTO admin_role (role_name,description,policy,active,created_at)
  VALUES ('Local Super','local e2e super admin',
    '{"policies":[{"name":"super_permission"},{"name":"list_tree"},{"name":"approve_tree"},{"name":"list_user"},{"name":"manager_user"}]}'::json,
    true, now()) RETURNING id
), u AS (
  INSERT INTO admin_user (user_name,password_hash,salt,email,active,enabled,created_at)
  VALUES (:'user',:'hash',:'salt',:'email', true, true, now()) RETURNING id
)
INSERT INTO admin_user_role (role_id, admin_user_id, active) SELECT r.id, u.id, true FROM r, u;
COMMIT;
SQL
info "seeded admin user '$user' (super role)  - ADMIN_URL=$GATEWAY_URL"
