#!/usr/bin/env bash
#
# down.sh - tear down the local Greenstand environment. Adapter-aware: the namespaces, images
# and down hooks come from the same k3s/services/*/standalone.yaml adapters up.sh discovers,
# processed in REVERSE dependency order, so teardown stays symmetric with stand-up and never
# needs editing when a subsystem is added.
#
# Default (local): delete the whole k3d cluster - removes all pods, namespaces AND Postgres data -
# then run every adapter's down hook (e.g. remove the host-side LocalStack container).
# Flags:
#   --namespaces   only delete the adapters' namespaces (keep the cluster + its data; skips hooks)
#   --images       also remove the adapters' built/pulled images from the host Docker
#
# Does NOT touch: any real cluster, real AWS resources, or your host tools.
#
# Env: ENV=local (default) uses k3d; ENV=ci deletes only the namespaces on $KUBE_CONTEXT.
#
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/orchestrator-lib.sh"

MODE="cluster"; CLEAN_IMAGES=0
for a in "$@"; do case "$a" in
  --namespaces) MODE="namespaces" ;;
  --images)     CLEAN_IMAGES=1 ;;
  *) die "unknown flag '$a' (use --namespaces and/or --images)" ;;
esac; done

command -v yq >/dev/null 2>&1 || die "yq missing - run ./k3s/prepare.sh (or ./k3s/prepare-linux.sh)"

# ── Adapter discovery (reverse order) ────────────────────────────────────────
# Namespaces, images and down hooks, gathered from every adapter. Order does not matter for
# namespace deletion (async) or image removal; down hooks run after the cluster is gone.
NAMESPACES=""
IMAGES=""
DOWN_HOOKS=""
for f in "$ADAPTERS_DIR"/*/standalone.yaml; do
  [ -f "$f" ] || continue
  NAMESPACES="$NAMESPACES $(yq -r '(.namespaces // []) | join(" ")' "$f")"
  IMAGES="$IMAGES $(yq -r '(.images // []) | map(.pull // (.name + ":local")) | join(" ")' "$f")"
  h=$(yq -r '.hooks.down // ""' "$f")
  [ -n "$h" ] && DOWN_HOOKS="$DOWN_HOOKS $h"
done
[ -n "$(echo $NAMESPACES)" ] || die "no adapters found under $ADAPTERS_DIR (*/standalone.yaml)"

# kill any lingering host-side port-forwards
pkill -f "port-forward svc/postgres" 2>/dev/null || true
pkill -f "port-forward svc/treetracker-admin-client" 2>/dev/null || true

delete_namespaces() {
  # SAFETY: never delete namespaces on a non-local cluster (e.g. the real dev cluster)
  case "$CONTEXT" in
    k3d-*) : ;;
    *) [ "$ENV" = ci ] || die "refusing to delete namespaces on non-k3d context '$CONTEXT' (set ENV=ci to override)";;
  esac
  log "deleting namespaces on $CONTEXT:$NAMESPACES"
  # shellcheck disable=SC2086
  kubectl --context "$CONTEXT" delete ns $NAMESPACES --ignore-not-found --wait=false 2>&1 | sed 's/^/  /' || true
}

run_down_hooks() {
  local h script
  for h in $DOWN_HOOKS; do
    script="$(abs_path "$h")"
    [ -f "$script" ] && bash "$script" || warn "down hook failed (non-fatal): $h"
  done
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
  run_down_hooks
else
  delete_namespaces   # ci with an existing (shared) cluster: only remove our namespaces
fi

if [ "$CLEAN_IMAGES" = 1 ]; then
  log "removing local images:$IMAGES"
  # shellcheck disable=SC2086
  docker rmi -f $IMAGES 2>/dev/null || true
fi

log "down complete"
