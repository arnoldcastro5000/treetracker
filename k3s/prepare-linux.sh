#!/usr/bin/env bash
#
# prepare-linux.sh - LOCAL MACHINE bootstrap for Linux hosts (including restricted-kernel
# sandboxes). The Linux sibling of the macOS-only prepare.sh. Installs the host tools that
# up.sh needs and, where the filesystem is symlink-hostile (virtiofs), provisions the ext4
# npm-cache fallback for db-migrate. Everything here is host setup; the portable stack setup
# lives in up.sh.
#
# Usage: ./k3s/prepare-linux.sh
#
# Versions are pinned to the set verified against this stack. Override via env if needed.
set -euo pipefail

KUBECTL_VER="${KUBECTL_VER:-v1.36.3}"
K3D_VER="${K3D_VER:-v5.9.0}"
HELM_VER="${HELM_VER:-v3.21.3}"
YQ_VER="${YQ_VER:-v4.44.3}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
SUBMODULE_BRANCH="${SUBMODULE_BRANCH:-k3s}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
log()  { echo "${c_grn}>${c_off} $*"; }
info() { echo "${c_dim}  $*${c_off}"; }
warn() { echo "${c_yel}! $*${c_off}"; }
die()  { echo "${c_red}x $*${c_off}" >&2; exit 1; }

# Shared retry seam (ticket 28) - sourced after the logging defs so its messages use this
# script's warn(). RETRY_BUDGET_SCALE widens every budget on a slow host or link; ENV=ci
# defaults tighter (matching orchestrator-lib.sh) because a CI minute is budgeted.
. "$ROOT/k3s/lib/retry.sh"
if [ -z "${RETRY_BUDGET_SCALE:-}" ] && [ "${ENV:-local}" = ci ]; then RETRY_BUDGET_SCALE=0.6; fi
# Per-attempt transfer ceiling for downloads, scaled by the same knob so a slow link widens
# this together with the outer budget. 120s inside the 180s deadline keeps headroom for a
# second attempt; a genuinely dead transfer is cut and retried.
CURL_MAX_TIME="${CURL_MAX_TIME:-$(retry_scaled_deadline 120)}"

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported arch $(uname -m)" ;;
esac

# sudo only when not already root, so this works both as root and as a normal user.
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

fetch() {   # fetch URL -> file, retrying transient failures (deadline-budgeted, ticket 28)
  # Inner guards make a single attempt bounded (a curl with no --max-time can hang forever,
  # and then no outer budget ever fires); curl's own --retry rides out mid-transfer blips.
  local url="$1" out="$2"
  retry 180 "download $url" \
    curl -fsSL --connect-timeout 10 --max-time "$CURL_MAX_TIME" --retry 3 -o "$out" "$url"
}

APT_UPDATED=0
apt_ensure() {   # apt_ensure <pkg> - one apt update per run, then install (retry-budgeted)
  # Acquire::Retries rides out per-fetch mirror blips inside one apt run; the outer retry
  # covers a transient index/lock failure of the run itself (ticket 28).
  local pkg="$1"
  if [ "$APT_UPDATED" = 0 ]; then
    retry 120 "apt update" \
      $SUDO apt-get update -qq -o Acquire::Retries=3 \
      || die "apt update failed (allow security.ubuntu.com, archive.ubuntu.com)"
    APT_UPDATED=1
  fi
  retry 120 "apt install $pkg" \
    $SUDO apt-get install -y -qq -o Acquire::Retries=3 "$pkg" \
    || die "$pkg install failed"
}

# -- 0. Submodules: pinned by default (shared logic; see k3s/lib/submodule-lib.sh) ----------
# FOLLOW_SUBMODULE_BRANCHES=1 is the developer opt-in that tracks the k3s branch tips. The
# old SKIP_SUBMODULE_BRANCHES=1 is no longer needed (the pinned default is a no-op in CI).
. "$ROOT/k3s/lib/submodule-lib.sh"
setup_submodules

# -- 1. Docker (must already be present; this script does not install the engine) ----------
log "docker"
command -v docker >/dev/null 2>&1 || die "docker not installed - install Docker Engine first"
docker info >/dev/null 2>&1 || die "Docker daemon not running"

# -- 2. kubectl ----------------------------------------------------------------------------
log "kubectl $KUBECTL_VER"
if [ "$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion": *"[^"]*"' | head -1)" = "\"gitVersion\": \"$KUBECTL_VER\"" ]; then
  info "already installed"
else
  fetch "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/${ARCH}/kubectl" /tmp/kubectl \
    || die "kubectl download failed (allow dl.k8s.io, cdn.dl.k8s.io)"
  $SUDO install -m0755 /tmp/kubectl "$BIN_DIR/kubectl"; rm -f /tmp/kubectl
fi

# -- 3. k3d (binary straight from GitHub releases; get.k3d.io redirect is flaky here) -------
log "k3d $K3D_VER"
if [ "$(k3d version 2>/dev/null | awk '/k3d version/{print $3}')" = "$K3D_VER" ]; then
  info "already installed"
else
  fetch "https://github.com/k3d-io/k3d/releases/download/${K3D_VER}/k3d-linux-${ARCH}" /tmp/k3d \
    || die "k3d download failed (allow github.com, objects.githubusercontent.com, release-assets.githubusercontent.com)"
  $SUDO install -m0755 /tmp/k3d "$BIN_DIR/k3d"; rm -f /tmp/k3d
fi

# -- 3b. yq (up.sh/down.sh read the stand-up adapters' standalone.yaml with it) -------------
log "yq $YQ_VER"
if [ "$(yq --version 2>/dev/null | grep -o "$YQ_VER")" = "$YQ_VER" ]; then
  info "already installed"
else
  fetch "https://github.com/mikefarah/yq/releases/download/${YQ_VER}/yq_linux_${ARCH}" /tmp/yq \
    || die "yq download failed (allow github.com, objects.githubusercontent.com, release-assets.githubusercontent.com)"
  $SUDO install -m0755 /tmp/yq "$BIN_DIR/yq"; rm -f /tmp/yq
fi

# -- 4. helm -------------------------------------------------------------------------------
log "helm $HELM_VER"
if [ "$(helm version --short 2>/dev/null | grep -o "^${HELM_VER}")" = "$HELM_VER" ]; then
  info "already installed"
else
  fetch "https://get.helm.sh/helm-${HELM_VER}-linux-${ARCH}.tar.gz" /tmp/helm.tgz \
    || die "helm download failed (allow get.helm.sh)"
  tar -xzf /tmp/helm.tgz -C /tmp
  $SUDO install -m0755 "/tmp/linux-${ARCH}/helm" "$BIN_DIR/helm"
  rm -rf /tmp/helm.tgz "/tmp/linux-${ARCH}"
fi

# -- 5. postgresql-client (host psql; up.sh uses it over the port-forward) ------------------
log "postgresql-client"
if command -v psql >/dev/null 2>&1; then
  info "already installed ($(psql --version))"
else
  apt_ensure postgresql-client
fi

# -- 5b. jq (e2e-lib.sh and the report scripts parse JSON with it) ---------------------------
log "jq"
if command -v jq >/dev/null 2>&1; then
  info "already installed ($(jq --version 2>/dev/null))"
else
  apt_ensure jq
fi

# -- 6. aws CLI (OPTIONAL: only the consumer step needs it; up.sh skips consumer without) ---
log "aws cli (optional)"
if command -v aws >/dev/null 2>&1; then
  info "already installed ($(aws --version 2>&1))"
elif fetch "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" /tmp/awscli.zip; then
  ( cd /tmp && unzip -qo awscli.zip && $SUDO ./aws/install --update ) && rm -rf /tmp/aws /tmp/awscli.zip
else
  warn "aws cli not installed (host allowlist may block awscli.amazonaws.com)."
  warn "  Not required: up.sh skips the SQS consumer without AWS creds; smoke.sh injects directly."
fi

# -- 7. node (needed by up.sh for db-migrate + admin-user seed) -----------------------------
log "node"
command -v node >/dev/null 2>&1 && info "node $(node --version)" \
  || warn "node not found - install Node (up.sh needs it for db-migrate and seeding)"

# -- 8. ext4 npm-cache fallback for F6 layer-2 (symlink-hostile virtiofs) -------------------
# up.sh first tries `npm install --no-bin-links` (layer 1). If that fails on this filesystem,
# db-migrate needs a real ext4 node_modules. This provisions loopback ext4 images and mounts
# them over the two nextgen node_modules. Opt-in (SETUP_NM_CACHE=1) because it needs mount
# privileges and does NOT survive a sandbox restart, so it must be re-run after each restart.
setup_nm_cache() {
  local root="${HOME}/.nm-cache"
  mkdir -p "$root"
  for name in treetracker data_pipeline; do
    local img="$root/${name}.ext4" dir="$root/nextgen-${name}"
    mkdir -p "$dir"
    if ! mountpoint -q "$dir"; then
      [ -f "$img" ] || { truncate -s 2G "$img"; mkfs.ext4 -q "$img"; }
      $SUDO mount -o loop "$img" "$dir" || { warn "mount $dir failed (needs privilege); relying on --no-bin-links"; return 0; }
      $SUDO chown "$(id -u):$(id -g)" "$dir"
    fi
    info "ext4 npm-cache ready: $dir"
  done
}
if [ "${SETUP_NM_CACHE:-0}" = 1 ]; then
  log "ext4 npm-cache (F6 layer-2)"
  setup_nm_cache
else
  info "ext4 npm-cache fallback skipped (up.sh tries --no-bin-links first; re-run with SETUP_NM_CACHE=1 if it fails)"
fi

log "prepare-linux complete - now run: ./k3s/up.sh"
