# Shared helpers + bulk-pack fixtures for the k3s e2e scripts (smoke.sh, route2-two-file-test.sh).
# Sourced, not executed. Keeping the pack schema in ONE place stops the two scripts drifting when
# the app's upload shape changes. Portable across macOS (bash 3.2) and Linux.

CLUSTER="${CLUSTER:-greenstand}"
CONTEXT="${KUBE_CONTEXT:-k3d-$CLUSTER}"

k()   { kubectl --context "$CONTEXT" "$@"; }
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
psq() { k exec -n data deploy/postgres -- psql -qtAX -U postgres -d "$1" -c "$2" 2>&1; }
# uuidgen is native on macOS, absent in some Linux sandboxes; fall back to python3.
uuid(){ if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; else python3 -c 'import uuid;print(uuid.uuid4())'; fi; }

# num "<psq output>" -> the value if it is a bare integer, else 0. Guards the numeric comparisons
# against psq folding a transient psql error string (stderr is merged) into the value.
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

# Build a v2 bulk pack. The reg/cap toggles let one builder emit the combined pack (smoke.sh) and
# each half of the real two-file upload (route2-two-file-test.sh) from a single field schema.
#   pack_json WR_ID DC_ID SES_ID CAP_ID WALLET PHONE NOW NOTE REG(1|0) CAP(1|0)
# field-data's legacy replication resolves the planter with `phone = <wallet> OR email = <wallet>`
# (Legacy/PlanterRepository.js findUser), so the wallet identifier must equal the phone/email.
pack_json() {
  jq -nc --arg wr "$1" --arg dc "$2" --arg s "$3" --arg c "$4" --arg w "$5" --arg ph "$6" \
    --arg now "$7" --arg note "$8" --argjson reg "$9" --argjson cap "${10}" '{
    pack_format_version:"2", device_id:"e2e-device-0001",
    wallet_registrations: (if $reg==1 then [{id:$wr,wallet:$w,first_name:"E2E",last_name:"Test",
      phone:$ph,email:null,lat:0.5385,lon:33.1592,
      user_photo_url:"https://example.invalid/u.jpg",registered_at:$now}] else null end),
    device_configurations:(if $reg==1 then [{id:$dc,device_identifier:"e2e-device-0001",brand:"generic",
      model:"sandbox",device:"sandbox",serial:"E2E1",hardware:"virtual",manufacturer:"greenstand",
      app_build:1,app_version:"0.0.0-e2e",os_version:"14",sdk_version:34,logged_at:$now}] else null end),
    sessions:             (if $reg==1 then [{id:$s,device_configuration_id:$dc,
      originating_wallet_registration_id:$wr,organization:null,target_wallet:$w,
      check_in_photo_url:"https://example.invalid/c.jpg",
      track_url:"https://example.invalid/track.json",start_time:$now}] else null end),
    captures:             (if $cap==1 then [{id:$c,session_id:$s,image_url:"https://example.invalid/t.jpg",
      lat:0.5385,lon:33.1592,gps_accuracy:5,note:$note,abs_step_count:null,delta_step_count:null,
      rotation_matrix:null,extra_attributes:null,captured_at:$now}] else null end),
    tracks:null, messages:null, registrations:null, trees:null}'
}
