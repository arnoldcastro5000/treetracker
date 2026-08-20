#!/usr/bin/env bash
#
# up.sh — set up the whole Greenstand capture→verify backend on a k8s cluster. PURE / portable:
# no host-tool installs and no proxy fiddling (that's prepare.sh, run once on your local machine).
# Idempotent + readiness-gated: re-running repairs/continues rather than duplicating.
#
# Env (same script for local dev and cloud CI e2e):
#   ENV=local (default) — k3d on this machine; images via `k3d image import`
#   ENV=ci               — existing kube-context (KUBE_CONTEXT); images pushed to $IMAGE_REGISTRY
#
# Usage:
#   ./k3s/up.sh                 # all steps
#   ./k3s/up.sh postgres        # one step (cluster|infra_images|postgres|migrate|rabbitmq|localstack|field_data|...)
#   ./k3s/up.sh --rebuild       # force rebuild every image even if already in the cluster
#   ./k3s/up.sh --rebuild admin # force rebuild just one step's image
#
# Image builds are gated on presence in the cluster: a re-run SKIPS building/pulling any image
# already in the node's containerd (so an already-up stack is reconciled, not rebuilt), and only
# (re)builds images that are missing (self-heal after DiskPressure GC or `down.sh --images`).
# `--rebuild` forces the build past that gate and rolls the affected deployment so new code loads.
#
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
ENV="${ENV:-local}"
CLUSTER="${CLUSTER:-greenstand}"
CONTEXT="${KUBE_CONTEXT:-k3d-$CLUSTER}"
NODE="${K3D_NODE:-k3d-${CLUSTER}-server-0}"   # the k3d server container (for containerd image queries)
IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"          # ci: registry to push to; empty ⇒ k3d image import
REBUILD="${REBUILD:-0}"                        # 1 (or --rebuild) ⇒ build even if the image is already present
DISK_WARN_PCT="${DISK_WARN_PCT:-80}"          # warn (only) before a build once the Docker disk is this full
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K3S_DIR="$ROOT/k3s"
NEXTGEN="$ROOT/treetracker-database-nextgen"
ADMIN_CLIENT="$ROOT/treetracker-admin-client"
ADMIN_CLIENT_PORT="${ADMIN_CLIENT_PORT:-3001}"   # host port-forward → admin-client pod (ADMIN_URL for the e2e)

# Gateway exposure. NodePort (default) works everywhere including servicelb-less/restricted
# kernels; LoadBalancer keeps k3d's klipper LB for normal kernels / cloud. See step_cluster + F3.
GATEWAY_SERVICE_TYPE="${GATEWAY_SERVICE_TYPE:-NodePort}"
GATEWAY_NODEPORT_HTTP="${GATEWAY_NODEPORT_HTTP:-30080}"
GATEWAY_NODEPORT_HTTPS="${GATEWAY_NODEPORT_HTTPS:-30443}"

# Route 2 — fully-local object storage (top-level "Shared object storage" decision; capture-map
# tickets 14/16). LocalStack (S3 + SQS) runs as a host-side container on :4566, provisioned in one
# region (eu-central-1) end to end. In-cluster clients reach it via host.k3d.internal:4566; the
# Android emulator via 10.0.2.2:4566 (both are the host). Default on. USE_LOCALSTACK=0 opts out to
# real AWS, which up.sh does not orchestrate for this stand-up (the fully-local map retired it).
USE_LOCALSTACK="${USE_LOCALSTACK:-1}"
LOCALSTACK_IMAGE="${LOCALSTACK_IMAGE:-localstack/localstack:3.8}"
LOCALSTACK_NAME="${LOCALSTACK_NAME:-greenstand-localstack}"
LOCALSTACK_PORT="${LOCALSTACK_PORT:-4566}"
OBJECT_STORAGE_REGION="${OBJECT_STORAGE_REGION:-eu-central-1}"
BATCH_UPLOADS_BUCKET="${BATCH_UPLOADS_BUCKET:-treetracker-local-batch-uploads}"
IMAGES_BUCKET="${IMAGES_BUCKET:-treetracker-local-images}"
UPLOAD_QUEUE="${UPLOAD_QUEUE:-treetracker-local-queue}"

# Homebrew paths are macOS-only; guard them so Linux does not shell out to a missing `brew`.
[ "$(uname)" = Darwin ] && export PATH="/opt/homebrew/bin:$PATH"
export NO_PROXY="0.0.0.0,127.0.0.1,localhost,::1,.svc,.cluster.local"
export no_proxy="$NO_PROXY"
command -v psql >/dev/null 2>&1 || { [ "$(uname)" = Darwin ] && PATH="$(brew --prefix libpq 2>/dev/null)/bin:$PATH"; }
if ! command -v node >/dev/null 2>&1; then
  for d in "$HOME"/.nvm/versions/node/*/bin; do [ -x "$d/node" ] && PATH="$d:$PATH" && break; done
fi

# ── Helpers ─────────────────────────────────────────────────────────────────
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_ylw=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
log()  { echo "${c_grn}▶${c_off} $*"; }
info() { echo "${c_dim}  $*${c_off}"; }
die()  { echo "${c_red}✖ $*${c_off}" >&2; exit 1; }

# Every domain up.sh downloads from, named in the block hint below.
NET_HINT_DOMAINS="registry-1.docker.io auth.docker.io app.getambassador.io datawire-static-files.s3.amazonaws.com registry.npmjs.org registry.yarnpkg.com"
# Firewall-block diagnosis. The sandbox proxy answers a policy-blocked host with HTTP 403 and a
# body that starts "Blocked by network policy: …"; docker/kubectl/helm/npm all swallow that body,
# so a hard block looks like a transient/proxy failure. When a download fails we re-probe the host
# directly with curl: if it IS blocked, print the real 403 explanation + the fix and exit; if not
# (a genuinely transient error), return 0 so the caller can keep retrying / fall through to its
# own message. A block is deterministic, so there is nothing to gain by retrying it.
net_check_die() {   # $1 = what failed (for the message); $2 = host to probe
  local what="$1" host="$2" body
  body=$(curl -sS -m 8 "https://${host}/" 2>&1 || true)
  case "$body" in *"Blocked by network policy"*)
    echo "${c_red}✖ ${what}: blocked by the sandbox network policy${c_off}" >&2
    printf '%s\n' "$body" | sed 's/^/    /' >&2
    echo "  Allow it on your HOST, then re-run ./k3s/up.sh:" >&2
    echo "    sbx policy allow network ${host}" >&2
    echo "  (the full run also needs: ${NET_HINT_DOMAINS})" >&2
    exit 1 ;;
  esac
  return 0
}

k()      { kubectl --context "$CONTEXT" "$@"; }
pg_pod() { k -n data get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

ensure_image() {   # pull on host (retry transient EOF) if absent, then load into cluster
  local img="$1" i
  if ! build_needed "$img"; then info "$img present in cluster -> skip pull"; return 0; fi
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    for i in $(seq 1 10); do
      docker pull "$img" >/dev/null 2>&1 && break
      # A firewall block is deterministic and won't clear on retry, detect it on the first failed
      # attempt and fail fast with the real cause instead of spending the whole retry budget.
      [ "$i" = 1 ]  && net_check_die "docker pull $img" registry-1.docker.io
      [ "$i" = 10 ] && die "docker pull $img failed after 10 attempts (transient registry error, rerun, or check: docker pull $img)"
      info "pull $img: retry $i"; sleep 5
    done
  fi
  load_image "$img"
}
load_image() {
  local img="$1"
  if [ -n "$IMAGE_REGISTRY" ]; then
    docker tag "$img" "$IMAGE_REGISTRY/$img"; docker push "$IMAGE_REGISTRY/$img" >/dev/null
    # The cluster pulls from the registry, so the local build copies are dead weight. Drop both
    # the original tag and the registry tag to keep the builder host's disk from filling over a run.
    docker image rm -f "$img" "$IMAGE_REGISTRY/$img" >/dev/null 2>&1 || true
  else
    k3d image import "$img" -c "$CLUSTER" >/dev/null 2>&1 || die "k3d image import $img failed"
    # k3d import COPIES the image into the node's containerd, so the host Docker copy is now
    # redundant, and on this stack host Docker and the k3d node share one /var/lib/docker device,
    # so keeping both stores every image twice. Left unchecked the app image builds push a small
    # Docker disk into kubelet DiskPressure, which then GCs the local-only ":local" images (not in
    # any registry, so unrecoverable) and wedges the cluster. Drop the host copy right after import.
    # Non-fatal and cheap to reconstruct: built images are rebuilt by their step, and pulled base
    # images are re-fetched by ensure_image on the next run.
    docker image rm -f "$img" >/dev/null 2>&1 || true
  fi
  # Reclaim BuildKit cache too. It grows ~2GB across the service builds and lives on the same
  # /var/lib/docker device, so even with the per-image cleanup above a small (≈10GB) Docker disk
  # peaks near kubelet DiskPressure during the last (admin-client) build, verified: a fresh
  # `up.sh all` otherwise tops out ~88% used. Pruning after each import caps the on-disk cache at
  # roughly the in-flight build. Trade: a re-run rebuilds cold (the cache is regenerated), which is
  # the right call for never wedging the cluster over a few minutes of rebuild time.
  docker builder prune -f >/dev/null 2>&1 || true
}
# ── Image gate + self-heal ────────────────────────────────────────────────
# Is <name:tag> already loaded in the k3d node's containerd? Local imports show as
# docker.io/library/<name>:<tag> (or docker.io/<org>/<name>:<tag>), so match the repo tail + exact
# tag. ENV=ci has no local node (images live in a registry) → always report absent so ci rebuilds.
image_in_cluster() {   # $1 = name:tag
  [ "$ENV" = local ] || return 1
  local n="${1%:*}" t="${1##*:}"
  docker exec "$NODE" crictl images 2>/dev/null \
    | awk -v n="$n" -v t="$t" '$1 ~ ("(^|/)" n "$") && $2 == t {f=1} END{exit !f}'
}
# Should we build/pull <name:tag>? Yes if forced (--rebuild) or it is absent from the cluster.
build_needed() {   # $1 = name:tag
  [ "$REBUILD" = 1 ] && return 0
  image_in_cluster "$1" && return 1
  return 0
}
deploy_exists()  { k -n "$1" get deploy "$2" >/dev/null 2>&1; }
deploy_healthy() {   # $1 ns  $2 deploy, 0 iff readyReplicas == spec.replicas and > 0
  local want have
  want=$(k -n "$1" get deploy "$2" -o jsonpath='{.spec.replicas}'        2>/dev/null || true)
  have=$(k -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  [ -n "$want" ] && [ "$want" != 0 ] && [ "${have:-0}" = "$want" ]
}
# Docker host and the k3d node share one small /var/lib/docker device; a cold rebuild can tip
# kubelet into DiskPressure, which GCs the local-only :local images (unrecoverable). Warn once
# before building if the disk is already high, warn only, never block (per test plan).
_disk_warned=0
disk_preflight() {
  [ "$ENV" = local ] && [ "$_disk_warned" = 0 ] || return 0
  local pct
  pct=$(df -P /var/lib/docker 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')
  [ -n "$pct" ] || pct=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')
  if [ -n "$pct" ] && [ "$pct" -ge "$DISK_WARN_PCT" ]; then
    echo "${c_ylw}⚠ Docker disk ${pct}% full (>= ${DISK_WARN_PCT}%): a cold rebuild may trip kubelet DiskPressure and GC the local-only :local images. Proceeding (warn-only).${c_off}" >&2
    _disk_warned=1
  fi
  return 0
}
# Build the image only if the gate says so, apply the overlay, then bring the Deployment to Ready.
# Restart the pods only when we (re)built an image the Deployment was already using (so the new
# same-tag :local image actually loads) OR the Deployment is unhealthy (self-heal). A healthy,
# no-build re-run touches nothing → same ReplicaSet, same pods (idempotent).
build_deploy() {   # $1 tag  $2 build-ctx  $3 kustomize-dir  $4 namespace  $5 deploy  [$6 dockerfile]
  local tag="$1" ctx="$2" kdir="$3" ns="$4" dep="$5" dockerfile="${6:-}" existed=0 built=0 logf="/tmp/up-${5}-build.log"
  local df_args=(); [ -n "$dockerfile" ] && df_args=( -f "$dockerfile" )
  if deploy_exists "$ns" "$dep"; then existed=1; fi
  if build_needed "$tag"; then
    disk_preflight; info "building $tag"
    docker build -t "$tag" ${df_args[@]+"${df_args[@]}"} "$ctx" >"$logf" 2>&1 || die "$dep image build failed (see $logf)"
    load_image "$tag"; built=1
  else
    info "$tag present in cluster -> skip build"
  fi
  k apply -k "$kdir" >/dev/null
  finish_deploy "$ns" "$dep" "$built" "$existed"
}
finish_deploy() {   # $1 ns  $2 deploy  $3 built(0|1)  $4 existed-before(0|1)
  local ns="$1" dep="$2" built="$3" existed="$4" why=""
  if [ "$existed" = 1 ]; then
    if   [ "$built" = 1 ];              then why="rebuilt image"
    elif ! deploy_healthy "$ns" "$dep"; then why="unhealthy"
    fi
  fi
  if [ -n "$why" ]; then
    info "$dep: $why -> rollout restart"
    k -n "$ns" rollout restart "deploy/$dep" >/dev/null 2>&1 || true
  fi
  k -n "$ns" rollout status "deploy/$dep" --timeout=180s
}

wait_pg_ready() {
  local pod i; pod="$(pg_pod)"; [ -n "$pod" ] || die "no postgres pod"
  for i in $(seq 1 60); do
    k -n data exec "$pod" -- pg_isready -U postgres -d treetracker >/dev/null 2>&1 && return 0; sleep 2
  done; die "postgres never ready"
}
psql_admin() { k -n data exec -i "$(pg_pod)" -- psql -U postgres "$@"; }

PF_PID=""
start_pf() {
  pkill -f "port-forward svc/postgres" 2>/dev/null || true; sleep 1
  k -n data port-forward svc/postgres 5432:5432 >/tmp/up-pf.log 2>&1 & PF_PID=$!
  local i; for i in $(seq 1 30); do
    PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -tAc 'select 1' >/dev/null 2>&1 && return 0; sleep 1
  done; die "port-forward to postgres never came up"
}
stop_pf() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; PF_PID=""; }

# The virtiofs workspace forbids symlinks, so `npm install` needs --no-bin-links (verified).
# That leaves no node_modules/.bin shim, so db-migrate is invoked through its node entrypoint
# (db_migrate) rather than the bare `db-migrate` binary or `npm run migrate:up`. Harmless on a
# normal filesystem too. If npm still fails here, prepare-linux.sh SETUP_NM_CACHE=1 provides an
# ext4 node_modules fallback.
npm_install_local() {   # $1 = project dir
  ( cd "$1" && { [ -d node_modules ] || npm install --no-audit --no-fund --no-bin-links >/dev/null 2>&1; } ) \
    || { net_check_die "npm install in $1" registry.npmjs.org; die "npm install failed in $1 (symlink-hostile FS? run ./k3s/prepare-linux.sh with SETUP_NM_CACHE=1)"; }
}
db_migrate() {   # $1 = dir whose node_modules has db-migrate; $2.. = db-migrate args (CWD = config dir)
  node "$1/node_modules/db-migrate/bin/db-migrate" "${@:2}"
}

# F5: write the gitignored db-migrate config if absent (never clobber a developer's own file).
# Both point at the port-forward opened by start_pf; the optional schema key scopes field-data.
ensure_db_json() {   # $1 = path, $2 = optional schema
  [ -f "$1" ] && return 0
  local schema=""; [ -n "${2:-}" ] && schema=",\"schema\":\"$2\""
  cat > "$1" <<EOF
{"local":{"driver":"pg","host":"127.0.0.1","port":5432,"database":"treetracker","user":"postgres","password":"postgres"$schema}}
EOF
  info "generated $1"
}

# ── Steps ─────────────────────────────────────────────────────────────────
step_preflight() {   # CHECK only — never install/fix (that's prepare.sh)
  command -v docker >/dev/null 2>&1 || die "docker missing — run ./k3s/prepare.sh"
  docker info >/dev/null 2>&1 || die "Docker not running — run ./k3s/prepare.sh"
  command -v kubectl >/dev/null 2>&1 || die "kubectl missing — run ./k3s/prepare.sh"
  command -v node >/dev/null 2>&1 || die "node missing — run ./k3s/prepare.sh"
  command -v psql >/dev/null 2>&1 || die "psql missing — run ./k3s/prepare.sh"
  [ "$ENV" = local ] && { command -v k3d >/dev/null 2>&1 || die "k3d missing — run ./k3s/prepare.sh"; }
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
    # servicelb + the host port mapping depend on how the gateway is exposed (F3):
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

# Tags MUST match what the manifests deploy (postgres.yaml / rabbitmq.yaml) so the presence gate
# recognizes them on a re-run and the node serves them locally (in-cluster containerd has no proxy).
step_infra_images() { log "infra images"; ensure_image "postgis/postgis:15-3.4"; ensure_image "rabbitmq:3.13-management-alpine"; }

step_postgres() {
  log "postgres"
  k apply -f "$K3S_DIR/postgres.yaml" >/dev/null
  k -n data rollout status deploy/postgres --timeout=180s
  wait_pg_ready
  psql_admin -d postgres -tAc "select 1 from pg_database where datname='data_pipeline'" | grep -q 1 \
    || psql_admin -d postgres -c "CREATE DATABASE data_pipeline;" >/dev/null
  info "databases: treetracker, data_pipeline"
}

step_migrate() {
  log "db-migrate (treetracker, data_pipeline, field_data, treetracker-api)"
  start_pf
  npm_install_local "$NEXTGEN/treetracker"
  npm_install_local "$NEXTGEN/data_pipeline"
  # F5: field-data uses schema=field_data; treetracker-api uses no schema (it relies on the
  # treetracker,public search_path set below), matching each repo's expected local DB config.
  ensure_db_json "$ROOT/treetracker-field-data/database/database.json" field_data
  ensure_db_json "$ROOT/treetracker-api/database.json"
  # nextgen migrations: each nextgen dir has its own db-migrate. field-data + treetracker-api
  # reuse the treetracker one (the tool + pg driver), matching how the stack ran before.
  ( cd "$NEXTGEN/treetracker"   && db_migrate "$NEXTGEN/treetracker"   up -e local -t nextgen_migrations >/dev/null ) || die "treetracker nextgen migrate failed"
  ( cd "$NEXTGEN/data_pipeline" && db_migrate "$NEXTGEN/data_pipeline" up -e local -t nextgen_migrations >/dev/null ) || die "data_pipeline nextgen migrate failed"
  ( cd "$ROOT/treetracker-field-data/database" && db_migrate "$NEXTGEN/treetracker" up -e local >/dev/null ) \
    || die "field_data migrate failed"
  # treetracker-api owns grower_account/capture/tree/... in a `treetracker` schema.
  # DB default search_path=treetracker,public so uuid_generate_v4/PostGIS stay reachable.
  PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -d treetracker -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || die "treetracker schema setup failed"
CREATE SCHEMA IF NOT EXISTS treetracker;
ALTER DATABASE treetracker SET search_path TO treetracker, public;
SQL
  ( cd "$ROOT/treetracker-api" && db_migrate "$NEXTGEN/treetracker" up -e local --migrations-dir database/migrations/ >/dev/null ) \
    || die "treetracker-api migrate failed"
  stop_pf
  info "public.trees + field_data.* + data_pipeline.bulk_tree_upload + treetracker.grower_account/capture/tree ready"
}

step_rabbitmq() { log "rabbitmq"; k apply -f "$K3S_DIR/rabbitmq.yaml" >/dev/null; k -n rabbitmq rollout status deploy/rabbitmq --timeout=180s; }

# Emissary-ingress (OSS Ambassador) — the API gateway. Must run BEFORE the service overlays,
# which ship getambassador.io/v2 Mappings (need the CRDs). 3.x serves v2 via its conversion webhook.
EMISSARY_VER="${EMISSARY_VER:-3.12.2}"
EMISSARY_CHART_VER="${EMISSARY_CHART_VER:-8.12.2}"
step_gateway() {
  log "emissary-ingress (API gateway → localhost:8088)"
  k apply -f "https://app.getambassador.io/yaml/emissary/${EMISSARY_VER}/emissary-crds.yaml" >/dev/null 2>&1 \
    || { net_check_die "emissary CRD download" app.getambassador.io; die "emissary CRD apply failed"; }
  k wait --timeout=150s --for=condition=available deployment emissary-apiext -n emissary-system >/dev/null 2>&1 \
    || die "emissary-apiext never ready"
  helm --kube-context "$CONTEXT" repo add datawire https://app.getambassador.io >/dev/null 2>&1 || true
  helm --kube-context "$CONTEXT" repo update datawire >/dev/null 2>&1 || true
  # No `--wait` here. The chart's Service defaults to type LoadBalancer; in NodePort mode
  # servicelb is disabled, so that Service never receives an ingress IP and `helm --wait` blocks
  # on it until the timeout, failing (context deadline exceeded) BEFORE the patch below can
  # convert it. Install without waiting, patch the Service, then gate on the Deployment rollout
  # explicitly, which is the readiness that actually matters and works in both Service modes.
  helm --kube-context "$CONTEXT" upgrade --install emissary-ingress datawire/emissary-ingress \
    --version "$EMISSARY_CHART_VER" -n emissary --create-namespace >/tmp/up-emissary.log 2>&1 \
    || { net_check_die "emissary chart download" datawire-static-files.s3.amazonaws.com
         net_check_die "emissary chart index" app.getambassador.io
         die "emissary helm install failed (see /tmp/up-emissary.log)"; }
  # The chart defaults the Service to LoadBalancer; with servicelb disabled (NodePort mode)
  # that would stay <pending> forever. Pin the two NodePorts the k3d LB maps 8088/8443 onto.
  # A strategic-merge patch (merge key = port) sets type + nodePort while preserving the
  # chart's name/targetPort, so we do not need to know emissary's container ports. Patch
  # rather than helm --set (the chart's service.ports list is index-fragile under --set).
  # LoadBalancer mode keeps the chart default (no patch). Patch BEFORE waiting on rollout so a
  # LoadBalancer Service is never in the wait path.
  if [ "$GATEWAY_SERVICE_TYPE" = NodePort ]; then
    k -n emissary patch svc emissary-ingress -p "$(cat <<EOF
{"spec":{"type":"NodePort","ports":[
  {"port":80,"nodePort":${GATEWAY_NODEPORT_HTTP}},
  {"port":443,"nodePort":${GATEWAY_NODEPORT_HTTPS}}]}}
EOF
)" >/dev/null || die "emissary NodePort patch failed"
  fi
  k -n emissary rollout status deploy/emissary-ingress --timeout=300s || die "emissary-ingress deployment never ready"
  k apply -f "$K3S_DIR/emissary.yaml" >/dev/null   # Listener + wildcard Host
}

# LocalStack (S3 + SQS) — the fully-local object store for Route 2. A host-side container on :4566,
# provisioned idempotently in one region (eu-central-1) so the S3 event carries production's region.
# In-cluster clients reach it via host.k3d.internal:4566; the Android emulator via 10.0.2.2:4566.
# Conditional tier: skipped when USE_LOCALSTACK=0 (opt out to real AWS, not orchestrated here).
step_localstack() {
  if [ "$USE_LOCALSTACK" != 1 ]; then
    info "localstack: skipped (USE_LOCALSTACK=$USE_LOCALSTACK)"; return 0
  fi
  log "localstack (S3 + SQS on :$LOCALSTACK_PORT, region $OBJECT_STORAGE_REGION)"
  command -v docker >/dev/null 2>&1 || die "docker missing — run ./k3s/prepare.sh"
  # Image present? Pull once (a firewall block is deterministic → fail fast with the real cause).
  if ! docker image inspect "$LOCALSTACK_IMAGE" >/dev/null 2>&1; then
    local i
    for i in $(seq 1 10); do
      docker pull "$LOCALSTACK_IMAGE" >/dev/null 2>&1 && break
      [ "$i" = 1 ]  && net_check_die "docker pull $LOCALSTACK_IMAGE" registry-1.docker.io
      [ "$i" = 10 ] && die "docker pull $LOCALSTACK_IMAGE failed after 10 attempts"
      info "pull $LOCALSTACK_IMAGE: retry $i"; sleep 5
    done
  fi
  # Container lifecycle: reuse a running one, start a stopped one, else create. DEFAULT_REGION on
  # the container makes eu-central-1 its default so a bucket without an explicit constraint still
  # lands in-region; the provisioning below sets it explicitly regardless.
  if docker ps --filter "name=^/${LOCALSTACK_NAME}$" --filter status=running -q | grep -q .; then
    info "$LOCALSTACK_NAME already running"
  elif docker ps -a --filter "name=^/${LOCALSTACK_NAME}$" -q | grep -q .; then
    info "starting existing $LOCALSTACK_NAME"; docker start "$LOCALSTACK_NAME" >/dev/null
  else
    info "creating $LOCALSTACK_NAME"
    docker run -d --name "$LOCALSTACK_NAME" \
      -p "${LOCALSTACK_PORT}:4566" \
      -e SERVICES=s3,sqs -e DEFAULT_REGION="$OBJECT_STORAGE_REGION" \
      "$LOCALSTACK_IMAGE" >/dev/null || die "localstack container failed to start"
  fi
  # Readiness: the health endpoint must list s3 and sqs before provisioning.
  local i health
  for i in $(seq 1 60); do
    health=$(curl -s -m 3 "http://localhost:${LOCALSTACK_PORT}/_localstack/health" 2>/dev/null || true)
    case "$health" in *'"sqs"'*'"s3"'*|*'"s3"'*'"sqs"'*) break ;; esac
    sleep 2
  done
  case "$health" in *'"s3"'*'"sqs"'*|*'"sqs"'*'"s3"'*) : ;; *) die "localstack never became ready on :$LOCALSTACK_PORT (s3+sqs)" ;; esac
  # Provision idempotently via awslocal INSIDE the container (no host aws-cli dependency). Region is
  # forced to eu-central-1 for buckets and queue so S3 and SQS agree end to end (ticket 16). Bucket
  # create is not idempotent (409 on re-run) → tolerate; queue create + notification config are.
  local qarn="arn:aws:sqs:${OBJECT_STORAGE_REGION}:000000000000:${UPLOAD_QUEUE}"
  docker exec -i "$LOCALSTACK_NAME" env AWS_DEFAULT_REGION="$OBJECT_STORAGE_REGION" sh -s <<EOF >/dev/null 2>&1 || die "localstack provisioning failed"
set -e
awslocal s3api create-bucket --bucket "$BATCH_UPLOADS_BUCKET" --create-bucket-configuration LocationConstraint="$OBJECT_STORAGE_REGION" 2>/dev/null || true
awslocal s3api create-bucket --bucket "$IMAGES_BUCKET"        --create-bucket-configuration LocationConstraint="$OBJECT_STORAGE_REGION" 2>/dev/null || true
awslocal sqs create-queue --queue-name "$UPLOAD_QUEUE"
awslocal s3api put-bucket-notification-configuration --bucket "$BATCH_UPLOADS_BUCKET" \
  --notification-configuration '{"QueueConfigurations":[{"QueueArn":"$qarn","Events":["s3:ObjectCreated:*"]}]}'
EOF
  info "provisioned: s3://$BATCH_UPLOADS_BUCKET, s3://$IMAGES_BUCKET, sqs $UPLOAD_QUEUE ($OBJECT_STORAGE_REGION), S3→SQS notification"
}

# Ensure a namespace exists before imperative Secrets land in it (a single-step run may hit a step
# before the overlay that ships the Namespace has applied).
ensure_ns() { k create namespace "$1" --dry-run=client -o yaml | k apply -f - >/dev/null; }

step_field_data()     { log "treetracker-field-data";      build_deploy treetracker-field-data:local    "$ROOT/treetracker-field-data"    "$K3S_DIR/services/treetracker-field-data"    field-data-api      treetracker-field-data; }
step_treetracker_api(){ log "treetracker-api (grower_accounts)"; build_deploy treetracker-api:local  "$ROOT/treetracker-api"           "$K3S_DIR/services/treetracker-api"           treetracker-api     treetracker-api; }
step_images_api()     { log "images-api (resize/proxy behind admin-client /images)"; build_deploy images-api:local "$ROOT/images-api" "$K3S_DIR/services/images-api"                images-api          images-api; }
step_transformer_v2() { log "bulk-pack-transformer-v2";    build_deploy bulk-pack-transformer-v2:local  "$ROOT/bulk-pack-transformer-v2"  "$K3S_DIR/services/bulk-pack-transformer-v2"  bulk-pack-services  bulk-pack-transformer-v2; }
# v1 transformer (planter path). The processor routes wallet_registrations / sessions here; it writes
# the planter to the treetracker DB so field-data's LegacyTree check passes. Built from the vendored
# Dockerfile (ticket 15); the treetracker-DB secret is supplied imperatively (no SealedSecret locally).
step_transformer() {
  log "bulk-pack-transformer (v1 planter path)"
  ensure_ns bulk-pack-services
  k -n bulk-pack-services create secret generic treetracker-database-connection \
    --from-literal=db='postgresql://postgres:postgres@postgres.data.svc.cluster.local:5432/treetracker' \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  build_deploy bulk-pack-transformer:local "$ROOT/bulk-pack-transformer" \
    "$K3S_DIR/services/bulk-pack-transformer" bulk-pack-services bulk-pack-transformer \
    "$K3S_DIR/services/bulk-pack-transformer/Dockerfile"
}

# Processor is a CronJob (no Deployment): gate the build, apply the overlay. Its next scheduled Job
# creates a fresh pod that pulls the current :local image from containerd, so no rollout restart.
step_processor() {
  log "bulk-pack-processor (CronJob)"
  local tag=bulk-pack-processor:local
  if build_needed "$tag"; then
    disk_preflight; info "building $tag"
    docker build -t "$tag" "$ROOT/bulk-pack-processor" >/tmp/up-bulk-pack-processor-build.log 2>&1 \
      || die "processor image build failed (see /tmp/up-bulk-pack-processor-build.log)"
    load_image "$tag"
  else
    info "$tag present in cluster -> skip build"
  fi
  k apply -k "$K3S_DIR/services/bulk-pack-processor" >/dev/null
  info "cronjob scheduled (every minute); trigger now: kubectl -n bulk-pack-services create job bpp-now --from=cronjob/bulk-pack-processor"
}
step_consumer() {
  log "bulk-pack-consumer (SQS → data_pipeline.bulk_tree_upload)"
  # Fully-local default: the consumer reads the LocalStack queue via host.k3d.internal:4566 with
  # dummy creds (LocalStack accepts any). No real AWS, no secret to leak, so a re-run never clobbers
  # LocalStack config with real values (the old bug). USE_LOCALSTACK=0 would mean real AWS, which
  # up.sh does not orchestrate for this fully-local stand-up (the map retired the dev backend): skip
  # the consumer loudly (not fatal) so the rest of `up.sh all` still comes up.
  if [ "$USE_LOCALSTACK" != 1 ]; then
    info "SKIPPED: USE_LOCALSTACK=0 (real AWS) is not orchestrated here; the consumer code supports"
    info "  AWS_ENDPOINT-less real AWS, but wiring it is out of scope for the fully-local stand-up."
    return 0
  fi
  local ns=bulk-pack-services dep=bulk-pack-consumer
  ensure_ns "$ns"
  # Secrets the base Deployment reads. The SQS URL is the LocalStack queue reached from the cluster
  # via host.k3d.internal; the overlay adds AWS_ENDPOINT + AWS_REGION so the SDK talks to LocalStack.
  k -n "$ns" create secret generic bulk-pack-database-connection \
    --from-literal=db='postgresql://postgres:postgres@postgres.data.svc.cluster.local:5432/data_pipeline' \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$ns" create secret generic sqs-url \
    --from-literal=sqsUrl="http://host.k3d.internal:${LOCALSTACK_PORT}/000000000000/${UPLOAD_QUEUE}" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$ns" create secret generic aws-key-id --from-literal=accessKeyId=test \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$ns" create secret generic aws-key --from-literal=secretAccessKey=test \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  build_deploy bulk-pack-consumer:local "$ROOT/bulk-pack-consumer" \
    "$K3S_DIR/services/bulk-pack-consumer" "$ns" "$dep" \
    "$K3S_DIR/services/bulk-pack-consumer/Dockerfile"
  # Inject the LocalStack endpoint + region from up.sh's vars (not hardcoded in the overlay) so
  # LOCALSTACK_PORT / OBJECT_STORAGE_REGION are a single source of truth. The consumer reaches
  # LocalStack via the host (host.k3d.internal) on the host publish port LOCALSTACK_PORT. Idempotent:
  # `set env` is a no-op (no rollout) when the values already match.
  k -n "$ns" set env "deploy/$dep" \
    AWS_ENDPOINT="http://host.k3d.internal:${LOCALSTACK_PORT}" \
    AWS_REGION="$OBJECT_STORAGE_REGION" >/dev/null
  k -n "$ns" rollout status "deploy/$dep" --timeout=120s
}
step_keycloak()       { info "SKIPPED: admin stack uses the legacy user system — no Keycloak needed"; }
step_admin() {
  log "treetracker-admin-api"
  build_deploy treetracker-admin-api:local "$ROOT/treetracker-admin-api" "$K3S_DIR/services/treetracker-admin-api" admin-api treetracker-admin-api
  seed_admin_user
}

step_admin_client() {
  log "treetracker-admin-client (static SPA → served behind Ambassador)"
  # Vendored build config lives in k3s/services/ (admin-client pin tracks master/2.0.0, which
  # carries no deployment/ tree). App source is the build context; nginx.conf comes from the
  # `localdeploy` named build context.
  local acdir="$K3S_DIR/services/treetracker-admin-client"
  local tag=treetracker-admin-client:local ns=admin-client dep=treetracker-admin-client existed=0 built=0
  if deploy_exists "$ns" "$dep"; then existed=1; fi
  if build_needed "$tag"; then
    disk_preflight; info "building $tag"
    docker build -t "$tag" -f "$acdir/Dockerfile" \
      --build-context localdeploy="$acdir" "$ADMIN_CLIENT" \
      >/tmp/up-treetracker-admin-client-build.log 2>&1 || die "admin-client image build failed (see /tmp/up-treetracker-admin-client-build.log)"
    load_image "$tag"; built=1
  else
    info "$tag present in cluster -> skip build"
  fi
  k apply -f "$acdir/k8s.yaml" >/dev/null   # Deployment + Service + `/` Mapping
  finish_deploy "$ns" "$dep" "$built" "$existed"
  [ "$ENV" = local ] && check_gateway
}

# The gateway (Emissary via the k3d loadbalancer) is the single entry: http://localhost:8088.
# No port-forward — routing is by the shipped Mappings (/api/admin/, /images/, …) + admin-client `/`.
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8088}"
check_gateway() {
  local i code
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$GATEWAY_URL/" 2>/dev/null || true)
    [ "$code" = 200 ] && break; sleep 2
  done
  [ "$code" = 200 ] || die "gateway not serving admin-client at $GATEWAY_URL (code=$code)"
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST "$GATEWAY_URL/api/admin/auth/login" \
    -H 'Content-Type: application/json' -d "{\"userName\":\"${ADMIN_USER:-test}\",\"password\":\"${ADMIN_PASSWORD:-ieVyaGqyMX}\"}" 2>/dev/null || true)
  [ "$code" = 200 ] || die "gateway → admin-api login route not working ($GATEWAY_URL/api/admin/auth/login = $code)"
  info "ADMIN_URL=$GATEWAY_URL  (login: ${ADMIN_USER:-test} / ${ADMIN_PASSWORD:-ieVyaGqyMX}) — via Ambassador"
}

# Seed the legacy admin_user for the /verify login (username/password + HMAC-SHA512(pw,salt)).
seed_admin_user() {
  local user="${ADMIN_USER:-test}" pass="${ADMIN_PASSWORD:-ieVyaGqyMX}" salt hash POD
  salt=$(node -e "console.log(require('crypto').randomBytes(16).toString('hex'))")
  hash=$(node -e "console.log(require('crypto').createHmac('sha512','$salt').update('$pass').digest('hex'))")
  POD=$(k -n data get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
  k -n data exec -i "$POD" -- psql -U postgres -d treetracker >/dev/null <<SQL || die "admin user seed failed"
BEGIN;
DELETE FROM admin_user_role WHERE admin_user_id IN (SELECT id FROM admin_user WHERE user_name='$user');
DELETE FROM admin_user WHERE user_name='$user';
DELETE FROM admin_role WHERE role_name='Local Super';
WITH r AS (
  INSERT INTO admin_role (role_name,description,policy,active,created_at)
  VALUES ('Local Super','local e2e super admin',
    '{"policies":[{"name":"super_permission"},{"name":"list_tree"},{"name":"approve_tree"},{"name":"list_user"},{"name":"manager_user"}]}'::json,
    true, now()) RETURNING id
), u AS (
  INSERT INTO admin_user (user_name,password_hash,salt,email,active,enabled,created_at)
  VALUES ('$user','$hash','$salt','$user@greenstand.org', true, true, now()) RETURNING id
)
INSERT INTO admin_user_role (role_id, admin_user_id, active) SELECT r.id, u.id, true FROM r, u;
COMMIT;
SQL
  info "seeded admin user '$user' (super role)"
}

run_all() {
  step_cluster; step_coredns; step_infra_images; step_postgres; step_migrate; step_rabbitmq
  step_gateway   # BEFORE service overlays — they ship Ambassador Mappings (need the CRDs)
  step_localstack   # object store up before the consumer connects to its queue
  step_field_data; step_treetracker_api; step_transformer_v2; step_transformer; step_processor; step_consumer
  step_admin; step_images_api; step_admin_client
  log "done — full capture→verify backend up on $CONTEXT (gateway: $GATEWAY_URL)"
}

# Args: an optional step name plus the optional --rebuild flag, in any order.
STEP=""
for a in "$@"; do
  case "$a" in
    --rebuild) REBUILD=1 ;;
    -*)        die "unknown flag '$a' (only --rebuild is supported)" ;;
    *)         [ -z "$STEP" ] && STEP="$a" || die "unexpected extra argument '$a'" ;;
  esac
done
STEP="${STEP:-all}"

trap stop_pf EXIT
step_preflight
case "$STEP" in
  all) run_all ;;
  cluster|coredns|infra_images|postgres|migrate|rabbitmq|gateway|localstack|field_data|treetracker_api|images_api|transformer_v2|transformer|processor|consumer|keycloak|admin|admin_client) "step_${STEP}" ;;
  *)   die "unknown step '${STEP}'. steps: cluster coredns infra_images postgres migrate rabbitmq gateway localstack field_data treetracker_api images_api transformer_v2 transformer processor consumer keycloak admin admin_client (or 'all'); flags: --rebuild" ;;
esac
