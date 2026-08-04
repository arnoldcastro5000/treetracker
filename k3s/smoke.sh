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

CLUSTER="${CLUSTER:-greenstand}"
CONTEXT="${KUBE_CONTEXT:-k3d-$CLUSTER}"
GW="${GATEWAY_URL:-http://localhost:8088}"
ADMIN_USER="${ADMIN_USER:-test}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-ieVyaGqyMX}"

k()   { kubectl --context "$CONTEXT" "$@"; }
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
psq() { k exec -n data deploy/postgres -- psql -qtAX -U postgres -d "$1" -c "$2" 2>&1; }

# Preflight: required tooling + the k3d context must exist (fail loud, not mid-test).
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found (brew install jq / apt-get install -y jq)"; exit 2; }
kubectl config get-contexts "$CONTEXT" >/dev/null 2>&1 || { echo "FATAL: kube context '$CONTEXT' not found"; exit 2; }

# UUIDs: uuidgen is native on macOS, absent in some Linux sandboxes; fall back to python3.
uuid() { if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; else python3 -c 'import uuid;print(uuid.uuid4())'; fi; }
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
BADPODS=$(k get pods -A --no-headers 2>/dev/null \
  | awk '$4!="Running" && $4!="Completed" {print $1"/"$2"="$4}' | tr '\n' ' ')
[ -z "$BADPODS" ] && ok "all pods Running/Completed" || bad "unhealthy: $BADPODS"

echo "== 2. gateway routing (host:8088 -> serverlb -> NodePort 30080 -> emissary)"
for path in / /api/admin/; do
  c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$GW$path")
  [ "$c" != "000" ] && ok "$path -> HTTP $c" || bad "$path unreachable"
done

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
BULK=$(jq -nc --arg wr "$WR_ID" --arg dc "$DC_ID" --arg s "$SES_ID" --arg c "$CAP_ID" \
  --arg fp "$FP" --arg now "$NOW" --arg w "$WALLET" --arg ph "$PHONE" '{
  pack_format_version:"2", device_id:"smoketest0000001",
  wallet_registrations:[{id:$wr,wallet:$w,first_name:"Smoke",last_name:"Test",
    phone:$ph,email:null,lat:0.5385,lon:33.1592,
    user_photo_url:"https://example.invalid/u.jpg",registered_at:$now}],
  device_configurations:[{id:$dc,device_identifier:"smoketest0000001",brand:"generic",model:"sandbox",
    device:"sandbox",serial:"SMOKE1",hardware:"virtual",manufacturer:"greenstand",app_build:1,
    app_version:"0.0.0-smoke",os_version:"14",sdk_version:34,logged_at:$now}],
  sessions:[{id:$s,device_configuration_id:$dc,originating_wallet_registration_id:$wr,
    organization:null,target_wallet:$w,check_in_photo_url:"https://example.invalid/c.jpg",
    track_url:"https://example.invalid/track.json",start_time:$now}],
  captures:[{id:$c,session_id:$s,image_url:"https://example.invalid/t.jpg",lat:0.5385,lon:33.1592,
    gps_accuracy:5,note:$fp,abs_step_count:null,delta_step_count:null,rotation_matrix:null,
    extra_attributes:null,captured_at:$now}],
  tracks:null, messages:null, registrations:null, trees:null}')
# psql -c takes a single SQL statement and no backslash meta-commands, so stream the
# INSERT over stdin. bulk_data is dollar-quoted ($j$) - jq -c never emits that token.
INS=$(printf "insert into public.bulk_tree_upload (key,bucket_arn,event_time,bulk_data,processed)
values ('%s','arn:aws:s3:::treetracker-local-batch-uploads',now(),\$j\$%s\$j\$::jsonb,false) returning id;\n" \
  "$KEY" "$BULK" | k exec -i -n data deploy/postgres -- psql -qtAX -U postgres -d data_pipeline 2>&1)
[[ "$INS" =~ ^[0-9]+$ ]] && ok "inserted bulk_tree_upload id=$INS key=$KEY" || { bad "insert failed: $INS"; }
echo "      fingerprint note: $FP"

echo "== 7. wait for the capture to flow through (processor cronjob runs * * * * *)"
# Success signal is the row landing in field_data, NOT bulk_tree_upload.processed --
# see step 8 for why that flag can never flip on this stack.
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

echo "== 8. KNOWN DEFECT: bulk_tree_upload.processed cannot flip on this stack"
# process-bulk-uploads.js:31-49 POSTs every non-v2Only payload to BOTH transformers.
# k3s/up.sh deploys only bulk-pack-transformer-v2, so the v1 leg fails with
# getaddrinfo ENOTFOUND bulk-pack-transformer.bulk-pack-services -> shouldBeProcessed=false
# -> the UPDATE is skipped -> the row is reprocessed every 60s forever.
PF=$(psq data_pipeline "select processed from public.bulk_tree_upload where key='$KEY'")
if [ "$PF" = "t" ]; then
  ok "processed=true -- v1 transformer must now be deployed; delete this xfail block"
else
  echo "  XFAIL processed=$PF (expected: v1 transformer not deployed)"
  k get svc -n bulk-pack-services bulk-pack-transformer >/dev/null 2>&1 \
    && bad "v1 transformer Service EXISTS, so processed=false is a new bug" \
    || ok "confirmed root cause: no bulk-pack-transformer (v1) Service in the cluster"
fi

echo
echo "== result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
