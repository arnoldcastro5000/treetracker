# Shared config + helpers for the k3s orchestrator (up.sh / down.sh) and the adapter hooks
# (k3s/services/*/hooks/*.sh). Sourced, not executed. Portable: bash 3.2 (macOS) + Linux, so
# no associative arrays, no mapfile, no ${var^^}.
#
# Every value has an env-overridable default, so a hook can also run standalone:
#   . "$(dirname "$0")/../../../lib/orchestrator-lib.sh"

# ── Config ────────────────────────────────────────────────────────────────────
ENV="${ENV:-local}"
CLUSTER="${CLUSTER:-greenstand}"
CONTEXT="${KUBE_CONTEXT:-k3d-$CLUSTER}"
NODE="${K3D_NODE:-k3d-${CLUSTER}-server-0}"   # the k3d server container (for containerd image queries)
IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"          # ci: registry to push to; empty ⇒ k3d image import
REBUILD="${REBUILD:-0}"                        # 1 (or --rebuild) ⇒ build even if the image is already present
DISK_WARN_PCT="${DISK_WARN_PCT:-80}"          # warn (only) before a build once the Docker disk is this full
# Deployment rollout wait. Must be >= the slowest legitimate first-boot (Keycloak's startupProbe budget
# is 300s: Liquibase + realm import on a cold Postgres), so a slow-but-healthy start is not failed.
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"

# TT_ROOT = the treetracker repo root; K3S_DIR = its k3s/ dir. Derived from this file's location
# (k3s/lib/) unless the caller already exported them.
if [ -z "${TT_ROOT:-}" ]; then
  TT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
K3S_DIR="${K3S_DIR:-$TT_ROOT/k3s}"
ADAPTERS_DIR="${ADAPTERS_DIR:-$K3S_DIR/services}"
NEXTGEN="${NEXTGEN:-$TT_ROOT/treetracker-database-nextgen}"

# Resolve an adapter-declared path (repo-root relative, or absolute) to an absolute path. Shared
# by up.sh (overlays, hooks, images) and down.sh (down hooks).
abs_path() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$TT_ROOT/$1" ;; esac; }

# Gateway exposure. NodePort (default) works everywhere including servicelb-less/restricted
# kernels; LoadBalancer keeps k3d's klipper LB for normal kernels / cloud.
GATEWAY_SERVICE_TYPE="${GATEWAY_SERVICE_TYPE:-NodePort}"
GATEWAY_NODEPORT_HTTP="${GATEWAY_NODEPORT_HTTP:-30080}"
GATEWAY_NODEPORT_HTTPS="${GATEWAY_NODEPORT_HTTPS:-30443}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8088}"
EMISSARY_VER="${EMISSARY_VER:-3.12.2}"
EMISSARY_CHART_VER="${EMISSARY_CHART_VER:-8.12.2}"

# Fully-local object storage (top-level "Shared object storage" decision). LocalStack (S3 + SQS)
# runs as a host-side container on :4566, provisioned in one region (eu-central-1) end to end.
# In-cluster clients reach it via host.k3d.internal:4566; the Android emulator via 10.0.2.2:4566.
LOCALSTACK_IMAGE="${LOCALSTACK_IMAGE:-localstack/localstack:3.8}"
LOCALSTACK_NAME="${LOCALSTACK_NAME:-greenstand-localstack}"
LOCALSTACK_PORT="${LOCALSTACK_PORT:-4566}"
OBJECT_STORAGE_REGION="${OBJECT_STORAGE_REGION:-eu-central-1}"
BATCH_UPLOADS_BUCKET="${BATCH_UPLOADS_BUCKET:-treetracker-local-batch-uploads}"
IMAGES_BUCKET="${IMAGES_BUCKET:-treetracker-local-images}"
UPLOAD_QUEUE="${UPLOAD_QUEUE:-treetracker-local-queue}"

ADMIN_USER="${ADMIN_USER:-test}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-ieVyaGqyMX}"

# Keycloak identity tier (conditional; identity-coexistence decision). Realm `treetracker` is
# imported at container start; the master bootstrap admin lets a subsystem hook (kcadm) create its
# own confidential client. Every value here is a LOCAL DUMMY literal, never a real credential.
KEYCLOAK_REALM="${KEYCLOAK_REALM:-treetracker}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KEYCLOAK_TEST_USER="${KEYCLOAK_TEST_USER:-walletuser@example.org}"
KEYCLOAK_TEST_PASSWORD="${KEYCLOAK_TEST_PASSWORD:-walletpass}"
# In-cluster base URL a service uses to reach Keycloak; the browser/gateway path is /keycloak.
KEYCLOAK_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL:-http://keycloak.keycloak.svc.cluster.local:8080}"

# Wallet-app subsystem (dedicated DB, wallet-api schema `wallet` + queue plumbing; its own Keycloak
# confidential client; dedicated images bucket). All secrets are LOCAL DUMMY literals.
WALLET_APP_DB="${WALLET_APP_DB:-wallet_app}"
WALLET_IMAGES_BUCKET="${WALLET_IMAGES_BUCKET:-treetracker-local-wallet-images}"
KEYCLOAK_WALLET_CLIENT_ID="${KEYCLOAK_WALLET_CLIENT_ID:-wallet-app-user-dev-svc}"
KEYCLOAK_WALLET_CLIENT_SECRET="${KEYCLOAK_WALLET_CLIENT_SECRET:-wallet-app-dev-secret}"
WALLET_API_KEY="${WALLET_API_KEY:-FORTESTFORTESTFORTESTFORTESTFORTEST}"

# Shared browser-flow seed fixtures (the three wallet maps: deeper-wallet-flows, pending-transfer-accept,
# wallet-trust-management). THREE realm users A/B/C, each with wallet.id == its Keycloak sub (Keycloak 26
# ignores a client-supplied id, so the seed reads the sub back and adopts it). Tokens on A (send-loop)
# and on C (bumped: the seeded pending transfer + the trust-payoff send). Trust seeded ONLY A -> B.
# B reuses the shared realm test user so the login path stays continuous with the client verify.
WALLET_SEED_PASSWORD="${WALLET_SEED_PASSWORD:-$KEYCLOAK_TEST_PASSWORD}"
WALLET_SEED_A_EMAIL="${WALLET_SEED_A_EMAIL:-wallet-a@example.org}"
WALLET_SEED_A_NAME="${WALLET_SEED_A_NAME:-Buwagi Grower}"
WALLET_SEED_A_TOKENS="${WALLET_SEED_A_TOKENS:-20}"
WALLET_SEED_B_EMAIL="${WALLET_SEED_B_EMAIL:-$KEYCLOAK_TEST_USER}"
WALLET_SEED_B_NAME="${WALLET_SEED_B_NAME:-Kikonda School}"
WALLET_SEED_C_EMAIL="${WALLET_SEED_C_EMAIL:-wallet-c@example.org}"
WALLET_SEED_C_NAME="${WALLET_SEED_C_NAME:-Masaka Co-op}"
WALLET_SEED_C_TOKENS="${WALLET_SEED_C_TOKENS:-20}"

# Homebrew paths are macOS-only; guard them so Linux does not shell out to a missing `brew`.
[ "$(uname)" = Darwin ] && export PATH="/opt/homebrew/bin:$PATH"
export NO_PROXY="0.0.0.0,127.0.0.1,localhost,::1,.svc,.cluster.local"
export no_proxy="$NO_PROXY"
command -v psql >/dev/null 2>&1 || { [ "$(uname)" = Darwin ] && PATH="$(brew --prefix libpq 2>/dev/null)/bin:$PATH"; }
if ! command -v node >/dev/null 2>&1; then
  for _d in "$HOME"/.nvm/versions/node/*/bin; do [ -x "$_d/node" ] && PATH="$_d:$PATH" && break; done
fi
# prepare.sh/prepare-linux.sh install yq onto PATH (BIN_DIR, default /usr/local/bin). As a
# fallback, also look in ~/.local/bin for a user-local install (e.g. BIN_DIR override, no sudo).
command -v yq >/dev/null 2>&1 || PATH="$HOME/.local/bin:$PATH"

# ── Logging ───────────────────────────────────────────────────────────────────
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_ylw=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
log()  { echo "${c_grn}▶${c_off} $*"; }
info() { echo "${c_dim}  $*${c_off}"; }
warn() { echo "${c_ylw}⚠ $*${c_off}" >&2; }
die()  { echo "${c_red}✖ $*${c_off}" >&2; exit 1; }

# Every domain up.sh downloads from, named in the block hint below.
NET_HINT_DOMAINS="registry-1.docker.io auth.docker.io quay.io app.getambassador.io datawire-static-files.s3.amazonaws.com registry.npmjs.org registry.yarnpkg.com"

# The registry host to probe for a given image ref. Docker grammar: the first path segment is a
# registry ONLY when a slash follows it AND it carries a dot or colon (or is `localhost`); a bare
# `name[:tag]` (no slash) is Docker Hub even though its tag holds a colon. Lets net_check_die report
# the RIGHT host on a blocked pull (e.g. quay.io for the Keycloak image), not always Hub.
image_registry_host() {   # $1 = image ref -> registry host
  case "$1" in
    */*)
      local first="${1%%/*}"
      case "$first" in
        localhost|*.*|*:*) printf '%s' "$first" ;;
        *)                 printf 'registry-1.docker.io' ;;
      esac ;;
    *) printf 'registry-1.docker.io' ;;   # no slash => bare Docker Hub image (name[:tag])
  esac
}
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

# ── kubectl / postgres ───────────────────────────────────────────────────────
k()      { kubectl --context "$CONTEXT" "$@"; }
pg_pod() { k -n data get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

# Ensure a namespace exists before imperative Secrets land in it (secrets are created before the
# overlay that ships the Namespace has applied).
ensure_ns() { k create namespace "$1" --dry-run=client -o yaml | k apply -f - >/dev/null; }

wait_pg_ready() {
  local pod i; pod="$(pg_pod)"; [ -n "$pod" ] || die "no postgres pod"
  for i in $(seq 1 60); do
    k -n data exec "$pod" -- pg_isready -U postgres -d treetracker >/dev/null 2>&1 && return 0; sleep 2
  done; die "postgres never ready"
}
psql_admin() { k -n data exec -i "$(pg_pod)" -- psql -U postgres "$@"; }

# Idempotent CREATE DATABASE on the shared Postgres (data-stores decision: the orchestrator
# ensures each adapter-declared database exists before that adapter's hooks run).
ensure_database() {   # $1 = database name
  psql_admin -d postgres -tAc "select 1 from pg_database where datname='$1'" | grep -q 1 \
    || psql_admin -d postgres -c "CREATE DATABASE \"$1\";" >/dev/null
}

PF_PID=""
start_pf() {
  pkill -f "port-forward svc/postgres" 2>/dev/null || true; sleep 1
  k -n data port-forward svc/postgres 5432:5432 >/tmp/up-pf.log 2>&1 & PF_PID=$!
  local i; for i in $(seq 1 30); do
    PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -tAc 'select 1' >/dev/null 2>&1 && return 0; sleep 1
  done; die "port-forward to postgres never came up"
}
stop_pf() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; PF_PID=""; }

# ── Images ────────────────────────────────────────────────────────────────────
ensure_image() {   # pull on host (retry transient EOF) if absent, then load into cluster
  local img="$1" i
  if ! build_needed "$img"; then info "$img present in cluster -> skip pull"; return 0; fi
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    for i in $(seq 1 10); do
      docker pull "$img" >/dev/null 2>&1 && break
      # A firewall block is deterministic and won't clear on retry, detect it on the first failed
      # attempt and fail fast with the real cause instead of spending the whole retry budget.
      [ "$i" = 1 ]  && net_check_die "docker pull $img" "$(image_registry_host "$img")"
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
  # peaks near kubelet DiskPressure during the last (admin-client) build. Pruning after each import
  # caps the on-disk cache at roughly the in-flight build. Trade: a re-run rebuilds cold (the cache
  # is regenerated), which is the right call for never wedging the cluster.
  docker builder prune -f >/dev/null 2>&1 || true
}
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
# Docker host and the k3d node share one small /var/lib/docker device; a cold rebuild can tip
# kubelet into DiskPressure, which GCs the local-only :local images (unrecoverable). Warn once
# before building if the disk is already high, warn only, never block.
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

# ── Deployments ───────────────────────────────────────────────────────────────
deploy_exists()  { k -n "$1" get deploy "$2" >/dev/null 2>&1; }
deploy_healthy() {   # $1 ns  $2 deploy, 0 iff readyReplicas == spec.replicas and > 0
  local want have
  want=$(k -n "$1" get deploy "$2" -o jsonpath='{.spec.replicas}'        2>/dev/null || true)
  have=$(k -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  [ -n "$want" ] && [ "$want" != 0 ] && [ "${have:-0}" = "$want" ]
}
# Bring a Deployment to Ready. Restart the pods only when we (re)built an image the Deployment
# was already using (so the new same-tag :local image actually loads) OR the Deployment is
# unhealthy (self-heal). A healthy, no-build re-run touches nothing → same ReplicaSet, same pods.
finish_deploy() {   # $1 ns  $2 deploy  $3 force-roll(0|1: rebuilt image or changed secret)  $4 existed-before(0|1)
  local ns="$1" dep="$2" force="$3" existed="$4" why=""
  if [ "$existed" = 1 ]; then
    if   [ "$force" = 1 ];              then why="image/secret change"
    elif ! deploy_healthy "$ns" "$dep"; then why="unhealthy"
    fi
  fi
  if [ -n "$why" ]; then
    info "$dep: $why -> rollout restart"
    k -n "$ns" rollout restart "deploy/$dep" >/dev/null 2>&1 || true
  fi
  k -n "$ns" rollout status "deploy/$dep" --timeout="${ROLLOUT_TIMEOUT}s"
}

# ── node / db-migrate ─────────────────────────────────────────────────────────
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
# Write the gitignored db-migrate config if absent (never clobber a developer's own file).
# Both point at the port-forward opened by start_pf; the optional schema key scopes field-data.
ensure_db_json() {   # $1 = path, $2 = optional schema
  [ -f "$1" ] && return 0
  local schema=""; [ -n "${2:-}" ] && schema=",\"schema\":\"$2\""
  cat > "$1" <<EOF
{"local":{"driver":"pg","host":"127.0.0.1","port":5432,"database":"treetracker","user":"postgres","password":"postgres"$schema}}
EOF
  info "generated $1"
}
