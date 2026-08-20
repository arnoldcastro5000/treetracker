#!/usr/bin/env bash
# k3s local-stack smoke test - runs entirely inside the cluster, no device, no AWS.
# Injects a forged v2 bulk-pack row (the exact shape bulk-pack-consumer would have written
# from SQS+S3), then asserts it flows: processor -> transformer-v2 -> field-data ->
# treetracker-api, and is visible via the admin gateway.
#
# Portable across macOS (bash 3.2, BSD tr) and Linux. Every kubectl call is pinned to the
# k3d context, so the forged INSERT can never land on a real cluster even if the current
# kube-context points elsewhere.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/e2e-lib.sh"   # k/ok/bad/psq/uuid/num + pack_json (shared with route2-two-file-test.sh)

GW="${GATEWAY_URL:-http://localhost:8088}"
ADMIN_USER="${ADMIN_USER:-test}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-ieVyaGqyMX}"

# Preflight: required tooling + the k3d context must exist (fail loud, not mid-test).
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found (brew install jq / apt-get install -y jq)"; exit 2; }
kubectl config get-contexts "$CONTEXT" >/dev/null 2>&1 || { echo "FATAL: kube context '$CONTEXT' not found"; exit 2; }

# BSD tr dies ("Illegal byte sequence") on non-UTF8 bytes from /dev/urandom under a UTF-8
# locale; force the C locale for the byte-filtering.
FP="e2e-$(date +%s)-$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c6)"
WR_ID=$(uuid); DC_ID=$(uuid); SES_ID=$(uuid); CAP_ID=$(uuid)
# field-data's legacy replication resolves the planter with
#   planter WHERE phone = <wallet> OR email = <wallet>   (Legacy/PlanterRepository.js findUser)
# so the wallet identifier MUST equal the phone/email, not be a separate name.
PHONE="+1555$(date +%s)"; WALLET="$PHONE"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
KEY="$(date -u +%Y-%m-%d-%H-%M-%S)_${SES_ID}_smoke_captures.json"

echo "== 1. cluster health"
k get --raw='/readyz' >/dev/null 2>&1 && ok "apiserver readyz" || bad "apiserver readyz"
NR=$(k get nodes --no-headers 2>/dev/null | grep -cw Ready)
[ "$NR" -ge 1 ] && ok "$NR node(s) Ready" || bad "no Ready node"
# The processor is a CronJob firing every 60s, so a job pod is often mid-create
# (Pending/ContainerCreating) at any instant. Retry so a purely-transient state settles, but break
# out immediately on a genuinely-bad state (CrashLoop/Error/ImagePull/...) so real failures still
# fail fast rather than waiting out the whole window.
# Substring match on the STATUS field so Init:/prefix variants count too (Init:CrashLoopBackOff,
# CreateContainerConfigError). Every phase containing one of these tokens is a genuine failure;
# Running/Completed/ContainerCreating/Pending never do.
BAD_RE='CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull|OOMKilled|Evicted|InvalidImageName'
HARD=""; BADPODS=""
for attempt in $(seq 1 8); do
  # Exclude pods being deleted (Terminating): a rollout restart leaves the old ReplicaSet pod
  # terminating, and one that exits non-zero on SIGTERM briefly shows Error in the STATUS column.
  # That is not a stack fault, so drop pods with a set deletionTimestamp before the health check.
  TERMINATING=$(k get pods -A --no-headers \
    -o 'custom-columns=K:.metadata.namespace,N:.metadata.name,D:.metadata.deletionTimestamp' 2>/dev/null \
    | awk '$3!="<none>"{print $1"/"$2}')
  PODS=$(k get pods -A --no-headers 2>/dev/null | awk -v term="$TERMINATING" '
    BEGIN{ n=split(term,a," "); for(i=1;i<=n;i++) t[a[i]]=1 }
    !($1"/"$2 in t)')
  HARD=$(echo "$PODS" | awk -v re="$BAD_RE" '$4 ~ re {print $1"/"$2"="$4}' | tr '\n' ' ')
  [ -n "$HARD" ] && break
  BADPODS=$(echo "$PODS" | awk '$4!="Running" && $4!="Completed" {print $1"/"$2"="$4}' | tr '\n' ' ')
  [ -z "$BADPODS" ] && break
  sleep 5
done
if   [ -n "$HARD" ];    then bad "unhealthy: $HARD"
elif [ -z "$BADPODS" ]; then ok "all pods Running/Completed"
else bad "unhealthy: $BADPODS"; fi

echo "== 2. gateway routing (host:8088 -> serverlb -> NodePort 30080 -> emissary)"
# `/` MUST serve the admin-client (HTTP 200): a dropped `/` Mapping or a broken admin-client build
# would still answer non-000 (a 404 from emissary), so gate hard on 200 here. `/api/admin/` is an
# API root with no index route, so any non-000 answer proves the mapping routes (step 3 exercises
# a real endpoint on it).
c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$GW/")
[ "$c" = 200 ] && ok "/ -> HTTP 200 (admin-client served)" || bad "/ -> HTTP $c (expected 200, admin-client not served)"
c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$GW/api/admin/")
[ "$c" != "000" ] && ok "/api/admin/ -> HTTP $c" || bad "/api/admin/ unreachable"

echo "== 3. admin-api auth"
TOKEN=$(curl -s -m 15 -X POST "$GW/api/admin/auth/login" -H 'Content-Type: application/json' \
  -d "{\"userName\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASSWORD\"}" | jq -r '.token // empty')
[ -n "$TOKEN" ] && ok "login returned JWT (${#TOKEN} chars)" || bad "login returned no token"

echo "== 4. in-cluster service reachability (from the transformer pod)"
TP=$(k get pod -n bulk-pack-services -l app=bulk-pack-transformer-v2 -o name 2>/dev/null | head -1)
for target in http://treetracker-field-data.field-data-api/health \
              http://treetracker-api.treetracker-api/health; do
  c=$(k exec -n bulk-pack-services "${TP#pod/}" -- \
        wget -qS -O /dev/null -T 8 "$target" 2>&1 | grep -o 'HTTP/1.[01] [0-9]*' | tail -1)
  [ -n "$c" ] && ok "$target -> ${c##* }" || bad "$target unreachable in-cluster"
done

echo "== 5. DB reachable + schemas present"
for spec in "data_pipeline:public.bulk_tree_upload" "treetracker:field_data.raw_capture" "treetracker:treetracker.capture"; do
  db=${spec%%:*}; tbl=${spec#*:}
  n=$(psq "$db" "select count(*) from $tbl")
  [[ "$n" =~ ^[0-9]+$ ]] && ok "$db/$tbl rows=$n" || bad "$db/$tbl -> $n"
done

echo "== 6. inject forged bulk-pack row (bypasses Cognito/S3/SQS)"
# The combined pack (registrations + session + capture) from the shared builder, reg=1 cap=1.
BULK=$(pack_json "$WR_ID" "$DC_ID" "$SES_ID" "$CAP_ID" "$WALLET" "$PHONE" "$NOW" "$FP" 1 1)
# psql -c takes a single SQL statement and no backslash meta-commands, so stream the
# INSERT over stdin. bulk_data is dollar-quoted ($j$) - jq -c never emits that token.
INS=$(printf "insert into public.bulk_tree_upload (key,bucket_arn,event_time,bulk_data,processed)
values ('%s','arn:aws:s3:::treetracker-local-batch-uploads',now(),\$j\$%s\$j\$::jsonb,false) returning id;\n" \
  "$KEY" "$BULK" | k exec -i -n data deploy/postgres -- psql -qtAX -U postgres -d data_pipeline 2>&1)
[[ "$INS" =~ ^[0-9]+$ ]] && ok "inserted bulk_tree_upload id=$INS key=$KEY" || { bad "insert failed: $INS"; }
echo "      fingerprint note: $FP"

echo "== 7. wait for the capture to flow through (processor cronjob runs * * * * *)"
# Success signal is the row landing in field_data; step 8 then asserts processed flips true.
RC=0
for i in $(seq 1 30); do
  RC=$(psq treetracker "select count(*) from field_data.raw_capture where note='$FP'")
  [ "$RC" = "1" ] && break
  sleep 5
done
[ "$RC" = "1" ] \
  && ok "capture reached field_data.raw_capture after ~$((i*5))s (processor -> transformer-v2 -> field-data)" \
  || bad "capture never landed after 150s (raw_capture count=$RC)"
for tbl in field_data.wallet_registration field_data.session field_data.device_configuration; do
  n=$(psq treetracker "select count(*) from $tbl")
  [ "$n" -ge 1 ] && ok "$tbl populated (rows=$n)" || bad "$tbl empty"
done

echo "== 8. bulk_tree_upload.processed flips true (v1 + v2 transformers both deployed)"
# process-bulk-uploads.js POSTs every non-v2Only payload to BOTH transformers. up.sh now deploys
# v1 (bulk-pack-transformer) alongside v2, so both legs succeed, shouldBeProcessed=true, and the
# processor flips processed=true. The flip happens on a processor cycle after the field_data
# landing above, so poll (the cronjob runs every 60s).
PF=""
for i in $(seq 1 24); do
  PF=$(psq data_pipeline "select processed from public.bulk_tree_upload where key='$KEY'")
  [ "$PF" = "t" ] && break
  sleep 5
done
[ "$PF" = "t" ] \
  && ok "processed=true after ~$((i*5))s (processor -> v1 + v2 transformers)" \
  || bad "processed=$PF after 120s -- the v1 transformer leg is failing"

echo
echo "== result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
