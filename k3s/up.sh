#!/usr/bin/env bash
#
# up.sh - the adapter-discovering orchestrator for the stand-alone Greenstand environment.
# PURE / portable: no host-tool installs and no proxy fiddling (that's prepare.sh, run once).
# Idempotent + readiness-gated: re-running repairs/continues rather than duplicating.
#
# Subsystems are STAND-UP ADAPTERS discovered by glob: every k3s/services/*/standalone.yaml is
# one adapter (see k3s/services/README.md for the schema). Adding a repo to the environment =
# adding one adapter folder; this orchestrator is never edited.
#
# Usage:
#   ./k3s/up.sh                     # stand up every subsystem (+ the tier services they need)
#   ./k3s/up.sh capture             # one subsystem + its transitive dependsOn
#   ./k3s/up.sh plan [subsystem]    # print the resolved stand-up order; touches nothing
#   ./k3s/up.sh verify [subsystem]  # run only the declared verify hooks of the selection
#   ./k3s/up.sh --rebuild [...]     # force rebuild images even if already in the cluster
#   ./k3s/up.sh --no-verify [...]   # skip the final verify phase (iteration speed)
#
# Env (same script for local dev and cloud CI e2e):
#   ENV=local (default) - k3d on this machine; images via `k3d image import`
#   ENV=ci               - existing kube-context (KUBE_CONTEXT); images pushed to $IMAGE_REGISTRY
#
# Image builds are gated on presence in the cluster: a re-run SKIPS building/pulling any image
# already in the node's containerd (so an already-up stack is reconciled, not rebuilt), and only
# (re)builds images that are missing (self-heal after DiskPressure GC or `down.sh --images`).
# `--rebuild` forces the build past that gate and rolls the affected deployments so new code loads.
#
# The stand-up contract per adapter: ensure namespaces -> create declared dummy secrets -> ensure
# declared databases (shared Postgres) -> provision declared object storage (shared LocalStack) ->
# pre hook -> build/pull images -> apply overlay -> up hook -> waitFor rollouts -> post hook.
# After every selected adapter is up, each declared `verify` runs as a HARD GATE, so
# "up.sh succeeded" means "the environment works" (skippable via --no-verify).
#
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/orchestrator-lib.sh"

# ── CLI ───────────────────────────────────────────────────────────────────────
VERB="up"; TARGET=""; NO_VERIFY="${NO_VERIFY:-0}"
for a in "$@"; do
  case "$a" in
    --rebuild)   REBUILD=1 ;;
    --no-verify) NO_VERIFY=1 ;;
    -*)          die "unknown flag '$a' (flags: --rebuild --no-verify)" ;;
    plan|verify) [ "$VERB" = up ] && VERB="$a" || die "unexpected extra argument '$a'" ;;
    *)           [ -z "$TARGET" ] && TARGET="$a" || die "unexpected extra argument '$a'" ;;
  esac
done
TARGET="${TARGET:-all}"

# ── Adapter discovery ─────────────────────────────────────────────────────────
# Parallel indexed arrays (macOS bash 3.2: no associative arrays). One yq read per adapter.
# down hooks are read by down.sh (its own light parse of the same contract), not up.sh, so this
# set omits A_DOWN.
A_NAME=(); A_DIR=(); A_TIER=(); A_OPTIN=(); A_DEPS=(); A_NS=(); A_DBS=()
A_OVERLAY=(); A_VERIFY=(); A_PRE=(); A_UP=(); A_POST=()

require_yq() { command -v yq >/dev/null 2>&1 || die "yq missing - run ./k3s/prepare.sh (or ./k3s/prepare-linux.sh)"; }

# One yq eval per field: tab/newline-joined multi-field reads mis-split on empty fields
# (tab is IFS whitespace, so empty fields collapse and everything shifts). Discovery runs once,
# so the extra execs are negligible.
yq_field() { yq -r "$1" "$2"; }
discover_adapters() {
  local f dir name
  for f in "$ADAPTERS_DIR"/*/standalone.yaml; do
    [ -f "$f" ] || continue
    dir="$(cd "$(dirname "$f")" && pwd)"
    name=$(yq_field '.name // ""' "$f")
    [ -n "$name" ] && [ "$name" != null ] || die "adapter $f has no name"
    A_NAME[${#A_NAME[@]}]="$name"
    A_DIR[${#A_DIR[@]}]="$dir"
    A_TIER[${#A_TIER[@]}]="$(yq_field '.tier // ""' "$f")"
    A_OPTIN[${#A_OPTIN[@]}]="$(yq_field '.optIn // false' "$f")"
    A_DEPS[${#A_DEPS[@]}]="$(yq_field '(.dependsOn // []) | join(" ")' "$f")"
    A_NS[${#A_NS[@]}]="$(yq_field '(.namespaces // []) | join(" ")' "$f")"
    A_DBS[${#A_DBS[@]}]="$(yq_field '(.databases // []) | join(" ")' "$f")"
    A_OVERLAY[${#A_OVERLAY[@]}]="$(yq_field '.overlay // ""' "$f")"
    A_VERIFY[${#A_VERIFY[@]}]="$(yq_field '.verify // ""' "$f")"
    A_PRE[${#A_PRE[@]}]="$(yq_field '.hooks.pre // ""' "$f")"
    A_UP[${#A_UP[@]}]="$(yq_field '.hooks.up // ""' "$f")"
    A_POST[${#A_POST[@]}]="$(yq_field '.hooks.post // ""' "$f")"
  done
  [ ${#A_NAME[@]} -gt 0 ] || die "no adapters found under $ADAPTERS_DIR (*/standalone.yaml)"
}

aidx() {   # adapter name -> array index, or return 1
  local i
  for i in $(seq 0 $((${#A_NAME[@]} - 1))); do
    [ "${A_NAME[$i]}" = "$1" ] && { echo "$i"; return 0; }
  done
  return 1
}

validate_adapters() {
  local i j d ns seen_ns=" "
  for i in $(seq 0 $((${#A_NAME[@]} - 1))); do
    # unique names
    for j in $(seq 0 $((${#A_NAME[@]} - 1))); do
      [ "$i" != "$j" ] && [ "${A_NAME[$i]}" = "${A_NAME[$j]}" ] \
        && die "duplicate adapter name '${A_NAME[$i]}' (${A_DIR[$i]} and ${A_DIR[$j]})"
    done
    # deps must exist
    for d in ${A_DEPS[$i]}; do
      aidx "$d" >/dev/null || die "adapter '${A_NAME[$i]}' dependsOn unknown adapter '$d'"
    done
    # namespace groups must be collision-free across adapters (cluster-topology decision)
    for ns in ${A_NS[$i]}; do
      case "$seen_ns" in *" $ns "*) die "namespace '$ns' declared by more than one adapter" ;; esac
      seen_ns="$seen_ns$ns "
    done
  done
}

# ── Selection + ordering ──────────────────────────────────────────────────────
# Selection: named target -> target + transitive deps; all -> every subsystem (tier: unset,
# optIn false). Universal tier is always in; conditional tier only via dependsOn closure.
ORDER=()   # resolved stand-up order (names)

in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

resolve_selection() {
  local sel="" queue="" i n d
  if [ "$TARGET" = all ]; then
    for i in $(seq 0 $((${#A_NAME[@]} - 1))); do
      [ -z "${A_TIER[$i]}" ] && [ "${A_OPTIN[$i]}" != true ] && queue="$queue ${A_NAME[$i]}"
    done
  else
    aidx "$TARGET" >/dev/null || die "unknown subsystem '$TARGET'. adapters: ${A_NAME[*]}"
    queue="$TARGET"
  fi
  # universal tier is always part of the environment
  for i in $(seq 0 $((${#A_NAME[@]} - 1))); do
    [ "${A_TIER[$i]}" = universal ] && queue="$queue ${A_NAME[$i]}"
  done
  # transitive dependsOn closure
  while [ -n "$queue" ]; do
    n="${queue%% *}"; [ "$n" = "$queue" ] && queue="" || queue="${queue#* }"
    [ -z "$n" ] && continue
    in_list "$n" "$sel" && continue
    sel="$sel $n"
    i=$(aidx "$n")
    for d in ${A_DEPS[$i]}; do in_list "$d" "$sel" || queue="$queue $d"; done
  done

  # Topological order (Kahn-style scan). Deterministic: universal tier first, then
  # alphabetical among adapters whose selected deps are all ordered.
  local remaining ordered="" pass cand picked
  remaining=$(printf '%s\n' $sel | sort)
  while [ -n "$remaining" ]; do
    picked=""
    for pass in universal other; do
      for cand in $remaining; do
        i=$(aidx "$cand")
        if [ "$pass" = universal ]; then [ "${A_TIER[$i]}" = universal ] || continue
        else [ "${A_TIER[$i]}" = universal ] && continue; fi
        local ok=1
        for d in ${A_DEPS[$i]}; do
          in_list "$d" "$sel" || continue   # dep outside selection cannot happen (closure), safety
          in_list "$d" "$ordered" || { ok=0; break; }
        done
        [ "$ok" = 1 ] && { picked="$cand"; break; }
      done
      [ -n "$picked" ] && break
    done
    [ -n "$picked" ] || die "dependency cycle among: $(echo $remaining | tr '\n' ' ')"
    ordered="$ordered $picked"
    remaining=$(printf '%s\n' $remaining | grep -vx "$picked" || true)
  done
  ORDER=($ordered)
}

# ── Contract steps ───────────────────────────────────────────────────────────
# Expand ${VAR} placeholders from the orchestrator config (single source of truth for
# ports/regions/resource names) in adapter-declared values.
CONFIG_VARS="LOCALSTACK_PORT LOCALSTACK_NAME OBJECT_STORAGE_REGION BATCH_UPLOADS_BUCKET IMAGES_BUCKET UPLOAD_QUEUE GATEWAY_URL ADMIN_USER ADMIN_PASSWORD CLUSTER CONTEXT NODE"
expand_vars() {
  local s="$1" v
  for v in $CONFIG_VARS; do s="${s//\$\{$v\}/${!v}}"; done
  printf '%s' "$s"
}

run_hook() {   # $1 adapter-name  $2 hook-kind  $3 path (repo-root-relative or absolute)
  local name="$1" kind="$2" path="$3"
  [ -n "$path" ] || return 0
  local script; script=$(abs_path "$path")
  [ -f "$script" ] || die "$name: $kind hook not found ($path)"
  info "$kind hook: $path"
  bash "$script" || die "$name: $kind hook failed ($path)"
}

# Records into SECRETS_CHANGED_NS the namespaces whose secret content actually changed on apply.
# A Deployment reads secret values into env only at pod start, and a secretKeyRef never crosses
# namespaces, so a changed secret must roll the pods IN ITS OWN NAMESPACE (kustomize would
# hash-name a secretGenerator, but these hold config-expanded dummy literals created imperatively).
# up_adapter rolls only the waitFor deployments in those namespaces.
create_secrets() {   # $1 adapter index
  local i="$1" f="${A_DIR[$1]}/standalone.yaml" n cnt ns nm args key val out
  SECRETS_CHANGED_NS=""
  cnt=$(yq -r '.secrets // [] | length' "$f")
  [ "$cnt" -gt 0 ] || return 0
  for n in $(seq 0 $((cnt - 1))); do
    ns=$(yq -r ".secrets[$n].namespace" "$f"); nm=$(yq -r ".secrets[$n].name" "$f")
    args=()
    while IFS=$'\t' read -r key val; do
      [ -n "$key" ] || continue
      args[${#args[@]}]="--from-literal=$key=$(expand_vars "$val")"
    done < <(yq -r ".secrets[$n].literals | to_entries[] | [.key, .value] | @tsv" "$f")
    # ${args[@]+...}: macOS bash 3.2 treats an empty array as unbound under set -u.
    # kubectl apply prints "configured" when the content changed, "unchanged" otherwise.
    out=$(k -n "$ns" create secret generic "$nm" ${args[@]+"${args[@]}"} --dry-run=client -o yaml | k apply -f -)
    case "$out" in *configured*) in_list "$ns" "$SECRETS_CHANGED_NS" || SECRETS_CHANGED_NS="$SECRETS_CHANGED_NS $ns" ;; esac
  done
  info "secrets: $cnt declared (dummy literals)"
}

ensure_databases() {   # $1 adapter index
  local i="$1" db
  [ -n "${A_DBS[$i]}" ] || return 0
  wait_pg_ready
  for db in ${A_DBS[$i]}; do ensure_database "$db"; done
  info "databases ensured: ${A_DBS[$i]}"
}

provision_object_storage() {   # $1 adapter index
  local i="$1" f="${A_DIR[$1]}/standalone.yaml" b q n cnt script="set -e"$'\n'
  [ "$(yq -r '.objectStorage // "" | length' "$f")" != 0 ] || return 0
  docker ps --filter "name=^/${LOCALSTACK_NAME}$" --filter status=running -q | grep -q . \
    || die "${A_NAME[$i]} declares objectStorage but LocalStack is not running (is 'localstack' in its dependsOn?)"
  # Bucket create is not idempotent (409 on re-run) → tolerate; queue create + notification
  # config are. Region is forced everywhere so S3 and SQS agree end to end.
  while read -r b; do
    [ -n "$b" ] || continue; b=$(expand_vars "$b")
    script="${script}awslocal s3api create-bucket --bucket \"$b\" --create-bucket-configuration LocationConstraint=\"$OBJECT_STORAGE_REGION\" 2>/dev/null || true"$'\n'
  done < <(yq -r '.objectStorage.buckets // [] | .[]' "$f")
  while read -r q; do
    [ -n "$q" ] || continue; q=$(expand_vars "$q")
    script="${script}awslocal sqs create-queue --queue-name \"$q\" >/dev/null"$'\n'
  done < <(yq -r '.objectStorage.queues // [] | .[]' "$f")
  cnt=$(yq -r '.objectStorage.notifications // [] | length' "$f")
  for n in $(seq 0 $((cnt - 1))); do
    [ "$cnt" -gt 0 ] || break
    local nb nq nev qarn
    nb=$(expand_vars "$(yq -r ".objectStorage.notifications[$n].bucket" "$f")")
    nq=$(expand_vars "$(yq -r ".objectStorage.notifications[$n].queue"  "$f")")
    nev=$(yq -r ".objectStorage.notifications[$n].events | map(\"\\\"\" + . + \"\\\"\") | join(\",\")" "$f")
    qarn="arn:aws:sqs:${OBJECT_STORAGE_REGION}:000000000000:${nq}"
    script="${script}awslocal s3api put-bucket-notification-configuration --bucket \"$nb\" --notification-configuration '{\"QueueConfigurations\":[{\"QueueArn\":\"$qarn\",\"Events\":[$nev]}]}'"$'\n'
  done
  docker exec -i "$LOCALSTACK_NAME" env AWS_DEFAULT_REGION="$OBJECT_STORAGE_REGION" sh -s <<<"$script" >/dev/null \
    || die "${A_NAME[$i]}: object storage provisioning failed"
  info "object storage provisioned ($OBJECT_STORAGE_REGION)"
}

build_images() {   # $1 adapter index; appends rebuilt tags to REBUILT_IMAGES
  local i="$1" f="${A_DIR[$1]}/standalone.yaml" pull name ctx dockerfile extras tag logf
  # Every field is emitted with a leading "-" sentinel (stripped here): tab is IFS whitespace,
  # so a genuinely empty leading/middle TSV field would collapse and shift every later field
  # (same failure mode as discovery).
  while IFS=$'\t' read -r pull name ctx dockerfile extras; do
    pull="${pull#-}"; name="${name#-}"; ctx="${ctx#-}"; dockerfile="${dockerfile#-}"; extras="${extras#-}"
    [ -n "$pull$name" ] || continue
    if [ -n "$pull" ]; then
      ensure_image "$pull"
      continue
    fi
    tag="$name:local"
    if ! build_needed "$tag"; then info "$tag present in cluster -> skip build"; continue; fi
    disk_preflight; info "building $tag"
    local args=(-t "$tag")
    [ -n "$dockerfile" ] && args[${#args[@]}]="-f" && args[${#args[@]}]="$(abs_path "$dockerfile")"
    if [ -n "$extras" ]; then
      local pair kv_key kv_val
      for pair in ${extras//,/ }; do
        kv_key="${pair%%=*}"; kv_val="${pair#*=}"
        args[${#args[@]}]="--build-context"; args[${#args[@]}]="$kv_key=$(abs_path "$kv_val")"
      done
    fi
    logf="/tmp/up-${name}-build.log"
    docker build "${args[@]}" "$(abs_path "$ctx")" >"$logf" 2>&1 || die "${A_NAME[$i]}: $tag build failed (see $logf)"
    load_image "$tag"
    REBUILT_IMAGES="$REBUILT_IMAGES $tag"
  done < <(yq -r '.images // [] | .[] | [
      "-" + (.pull // ""), "-" + (.name // ""), "-" + (.context // ""), "-" + (.dockerfile // ""),
      "-" + ((.extraContexts // {}) | to_entries | map(.key + "=" + .value) | join(","))
    ] | @tsv' "$f")
}

up_adapter() {   # $1 adapter name
  local name="$1" i ns
  i=$(aidx "$name")
  log "── $name"
  for ns in ${A_NS[$i]}; do ensure_ns "$ns"; done
  SECRETS_CHANGED_NS=""
  create_secrets "$i"
  ensure_databases "$i"
  provision_object_storage "$i"
  run_hook "$name" pre "${A_PRE[$i]}"
  REBUILT_IMAGES=""
  build_images "$i"
  # Record which waitFor deployments existed BEFORE the apply, so finish_deploy can tell a
  # first-time create from a reconcile (only the latter may need a rollout restart).
  local wf_ns=() wf_dep=() wf_img=() wf_existed=() wns wdep wimg n=0
  while IFS=$'\t' read -r wns wdep wimg; do
    [ -n "$wns" ] || continue
    wf_ns[$n]="$wns"; wf_dep[$n]="$wdep"; wf_img[$n]="$wimg"
    if deploy_exists "$wns" "$wdep"; then wf_existed[$n]=1; else wf_existed[$n]=0; fi
    n=$((n + 1))
  done < <(yq -r '.waitFor // [] | .[] | [.namespace, .deployment, .image // ""] | @tsv' "${A_DIR[$i]}/standalone.yaml")
  if [ -n "${A_OVERLAY[$i]}" ]; then
    k apply -k "$(abs_path "${A_OVERLAY[$i]}")" >/dev/null
  fi
  run_hook "$name" up "${A_UP[$i]}"
  local j built
  for j in $(seq 0 $((n - 1))); do
    [ "$n" -gt 0 ] || break
    built=0
    [ -n "${wf_img[$j]}" ] && in_list "${wf_img[$j]}" "$REBUILT_IMAGES" && built=1
    # A changed secret in this deployment's namespace means its running pod holds stale env;
    # force a roll so it reloads (scoped to the namespace: a secretKeyRef never crosses one).
    local roll="$built"
    in_list "${wf_ns[$j]}" "${SECRETS_CHANGED_NS:-}" && roll=1
    finish_deploy "${wf_ns[$j]}" "${wf_dep[$j]}" "$roll" "${wf_existed[$j]}" \
      || die "$name: deployment ${wf_ns[$j]}/${wf_dep[$j]} never became ready"
  done
  run_hook "$name" post "${A_POST[$i]}"
}

run_verify() {   # $1 adapter name -> 0 ok / 1 failed; skips silently when none declared
  local name="$1" i v
  i=$(aidx "$name")
  v="${A_VERIFY[$i]}"
  [ -n "$v" ] || return 0
  log "verify: $name ($v)"
  bash "$(abs_path "$v")" || { echo "${c_red}✖ verify failed for subsystem '$name' ($v)${c_off}" >&2; return 1; }
}

# ── Cluster core (not adapters: the cluster itself + its DNS quirk) ──────────
step_preflight() {   # CHECK only - never install/fix (that's prepare.sh)
  command -v docker >/dev/null 2>&1 || die "docker missing - run ./k3s/prepare.sh"
  docker info >/dev/null 2>&1 || die "Docker not running - run ./k3s/prepare.sh"
  command -v kubectl >/dev/null 2>&1 || die "kubectl missing - run ./k3s/prepare.sh"
  command -v node >/dev/null 2>&1 || die "node missing - run ./k3s/prepare.sh"
  command -v psql >/dev/null 2>&1 || die "psql missing - run ./k3s/prepare.sh"
  [ "$ENV" = local ] && { command -v k3d >/dev/null 2>&1 || die "k3d missing - run ./k3s/prepare.sh"; }
  return 0
}

step_cluster() {
  if [ "$ENV" != local ]; then
    k get nodes >/dev/null 2>&1 || die "context $CONTEXT unreachable"; log "using cluster $CONTEXT"; return 0
  fi
  log "k3d cluster '$CLUSTER'"
  if k3d cluster list 2>/dev/null | grep -q "^$CLUSTER "; then
    k3d cluster start "$CLUSTER" >/dev/null 2>&1 || true
  else
    # These three flags are harmless on a normal kernel and required on restricted ones
    # (sandbox/CI): /dev/kmsg shim so kubelet boots, host-gw flannel (no vxlan module to
    # encapsulate), and a no-op conntrack tunable (the sysctl is read-only in-container).
    # servicelb + the host port mapping depend on how the gateway is exposed:
    #   NodePort   -> disable klipper, publish the emissary NodePort (30080/30443)
    #   LoadBalancer -> keep klipper, map the node's :80/:443
    local lb_args
    if [ "$GATEWAY_SERVICE_TYPE" = NodePort ]; then
      lb_args=( --k3s-arg "--disable=servicelb@server:*"
                -p "8088:${GATEWAY_NODEPORT_HTTP}@loadbalancer"
                -p "8443:${GATEWAY_NODEPORT_HTTPS}@loadbalancer" )
    else
      lb_args=( -p "8088:80@loadbalancer" -p "8443:443@loadbalancer" )
    fi
    k3d cluster create "$CLUSTER" \
      --k3s-arg "--disable=traefik@server:*" \
      --k3s-arg "--flannel-backend=host-gw@server:*" \
      --k3s-arg "--kube-proxy-arg=conntrack-max-per-core=0@server:*" \
      "${lb_args[@]}" \
      --agents 0 \
      -v /dev/null:/dev/kmsg@server:0
  fi
  kubectl config use-context "$CONTEXT" >/dev/null
  [ "$(kubectl config current-context)" = "$CONTEXT" ] || die "context is not $CONTEXT"
  # k3d writes the kubeconfig server as host.docker.internal, which this machine's
  # fake-IP DNS resolves to a bogus 198.18.x.x address → API unreachable (EOF). The
  # serverlb publishes 6443 on 0.0.0.0, so pin the server to 127.0.0.1 (in the cert SANs).
  if [ "$ENV" = local ]; then
    local srv port
    srv=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='$CONTEXT')].cluster.server}")
    port=${srv##*:}
    case "$srv" in *host.docker.internal*|*0.0.0.0*)
      kubectl config set-cluster "$CONTEXT" --server="https://127.0.0.1:$port" >/dev/null ;;
    esac
  fi
  # A freshly-created cluster's API server (and its OpenAPI aggregation, used by
  # `kubectl apply` client-side validation) lags a few seconds → "failed to download
  # openapi … EOF". Gate on readiness before anything applies.
  local i
  for i in $(seq 1 60); do
    [ "$(k get --raw=/readyz 2>/dev/null)" = "ok" ] && k get --raw=/openapi/v2 >/dev/null 2>&1 \
      && k get nodes 2>/dev/null | grep -q ' Ready' && break
    sleep 2
  done
  k get nodes 2>/dev/null | grep -q ' Ready' || die "cluster API/node never became ready"
}

# Alpine/musl pods inherit a `search <host>.docker.internal` suffix. When the host DNS answers
# NOERROR-with-no-records (not NXDOMAIN), musl's getaddrinfo stops the search walk instead of
# trying the next suffix, so every in-cluster name fails to resolve. Give CoreDNS an explicit
# NXDOMAIN zone for *.docker.internal so the walk continues. Harmless on glibc/normal setups;
# k3d's own host.k3d.internal lives in a different zone and is untouched. Idempotent.
step_coredns() {
  [ "$ENV" = local ] || { info "coredns: skipped (ENV=$ENV, not k3d)"; return 0; }
  log "coredns-custom (NXDOMAIN for *.docker.internal + host.k3d.internal → host gateway)"
  # k3d normally injects host.k3d.internal, but this custom cluster (host-gw flannel, servicelb
  # disabled) has no such record → in-cluster pods cannot reach a host-side service (LocalStack on
  # :4566). Map host.k3d.internal to the k3d docker-network gateway (= the host as seen from the
  # node), discovered at runtime, so the overlays' AWS_ENDPOINT=http://host.k3d.internal:4566 works.
  local gw
  gw=$(docker exec "$NODE" sh -c "ip route | awk '/default/{print \$3}'" 2>/dev/null || true)
  [ -n "$gw" ] || die "could not determine the k3d node's host gateway (is $NODE running?)"
  info "host.k3d.internal -> $gw"
  local rv_before rv_after
  rv_before=$(k -n kube-system get cm coredns-custom -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)
  k apply -f - >/dev/null <<YAML || die "coredns-custom apply failed"
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  docker-internal.server: |
    docker.internal:53 {
      template IN ANY {
        rcode NXDOMAIN
      }
    }
  k3d-internal.server: |
    k3d.internal:53 {
      hosts {
        $gw host.k3d.internal
        fallthrough
      }
    }
YAML
  rv_after=$(k -n kube-system get cm coredns-custom -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)
  # CoreDNS reloads the custom zone from the ConfigMap; only bounce it when that ConfigMap actually
  # changed (or was just created). An unchanged config needs no restart, so re-runs stay idempotent
  # (no CoreDNS pod churn) and faster. resourceVersion is stable across a no-op `kubectl apply`.
  if [ "$rv_before" != "$rv_after" ]; then
    info "coredns-custom changed (rv '${rv_before:-none}' -> '$rv_after') -> restart coredns"
    k -n kube-system rollout restart deploy/coredns >/dev/null
    k -n kube-system rollout status deploy/coredns --timeout=120s
  else
    info "coredns-custom unchanged -> skip coredns restart"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
require_yq
discover_adapters
validate_adapters
resolve_selection

# ${ORDER[@]+...} guards every expansion: bash < 4.4 (macOS 3.2) treats an empty array as unbound
# under set -u, so a selection that resolves to nothing must not crash the dispatch.
case "$VERB" in
  plan)
    [ ${#ORDER[@]} -gt 0 ] && printf '%s\n' "${ORDER[@]}"
    exit 0
    ;;
  verify)
    RC=0
    for name in ${ORDER[@]+"${ORDER[@]}"}; do run_verify "$name" || RC=1; done
    [ "$RC" = 0 ] || die "verify failed (see above)"
    log "verify green for: ${ORDER[*]+${ORDER[*]}}"
    ;;
  up)
    step_preflight
    step_cluster
    step_coredns
    for name in ${ORDER[@]+"${ORDER[@]}"}; do up_adapter "$name"; done
    if [ "$NO_VERIFY" = 1 ]; then
      info "verify skipped (--no-verify)"
    else
      for name in ${ORDER[@]+"${ORDER[@]}"}; do
        run_verify "$name" || die "stand-up verify failed for '$name' (re-run just this check: ./k3s/up.sh verify $name)"
      done
    fi
    log "done - environment up on $CONTEXT (gateway: $GATEWAY_URL), subsystems: ${ORDER[*]+${ORDER[*]}}"
    ;;
esac
