#!/usr/bin/env bash
#
# down.sh — tear down the local Greenstand backend.
#
# Default (local): delete the whole k3d cluster — removes all pods, namespaces AND Postgres data.
# Flags:
#   --namespaces   only delete the stack's namespaces (keep the cluster + its data)
#   --images       also remove the locally built/pulled images from the host Docker
#
# Does NOT touch: the online dev DB, the AWS `treetracker-local-*` resources, or your host tools.
#
# Env: ENV=local (default) uses k3d; ENV=ci deletes only the namespaces on $KUBE_CONTEXT.
#
set -euo pipefail

ENV="${ENV:-local}"
CLUSTER="${CLUSTER:-greenstand}"
CONTEXT="${KUBE_CONTEXT:-k3d-$CLUSTER}"
NAMESPACES=(admin-client admin-api bulk-pack-services treetracker-api images-api field-data-api rabbitmq data emissary emissary-system)

# Homebrew paths are macOS-only; guard so Linux does not prepend a nonexistent dir.
[ "$(uname)" = Darwin ] && export PATH="/opt/homebrew/bin:$PATH"
export NO_PROXY="0.0.0.0,127.0.0.1,localhost,::1,.svc,.cluster.local"
export no_proxy="$NO_PROXY"
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_off=$'\033[0m'
log(){ echo "${c_grn}▶${c_off} $*"; }
die(){ echo "${c_red}✖ $*${c_off}" >&2; exit 1; }

MODE="cluster"; CLEAN_IMAGES=0
for a in "$@"; do case "$a" in
  --namespaces) MODE="namespaces" ;;
  --images)     CLEAN_IMAGES=1 ;;
  *) die "unknown flag '$a' (use --namespaces and/or --images)" ;;
esac; done

# kill any lingering host-side port-forwards
pkill -f "port-forward svc/postgres" 2>/dev/null || true
pkill -f "port-forward svc/treetracker-admin-client" 2>/dev/null || true

delete_namespaces() {
  # SAFETY: never delete namespaces on a non-local cluster (e.g. the real dev cluster)
  case "$CONTEXT" in
    k3d-*) : ;;
    *) [ "$ENV" = ci ] || die "refusing to delete namespaces on non-k3d context '$CONTEXT' (set ENV=ci to override)";;
  esac
  log "deleting namespaces on $CONTEXT: ${NAMESPACES[*]}"
  kubectl --context "$CONTEXT" delete ns "${NAMESPACES[@]}" --ignore-not-found --wait=false 2>&1 | sed 's/^/  /' || true
}

if [ "$MODE" = namespaces ]; then
  delete_namespaces
elif [ "$ENV" = local ]; then
  if k3d cluster list 2>/dev/null | grep -q "^$CLUSTER "; then
    log "deleting k3d cluster '$CLUSTER' (all pods + data)"
    k3d cluster delete "$CLUSTER"
  else
    log "k3d cluster '$CLUSTER' not present"
  fi
else
  delete_namespaces   # ci with an existing (shared) cluster: only remove our namespaces
fi

if [ "$CLEAN_IMAGES" = 1 ]; then
  log "removing local images"
  docker rmi -f treetracker-field-data:local treetracker-api:local images-api:local bulk-pack-transformer-v2:local bulk-pack-processor:local bulk-pack-consumer:local treetracker-admin-api:local treetracker-admin-client:local postgis/postgis:15-3.4 rabbitmq:3.13-management 2>/dev/null || true
fi

log "down complete"
