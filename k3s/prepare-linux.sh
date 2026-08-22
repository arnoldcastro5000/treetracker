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

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported arch $(uname -m)" ;;
esac

# sudo only when not already root, so this works both as root and as a normal user.
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

fetch() {   # fetch URL -> file, retrying transient failures
  local url="$1" out="$2" i
  for i in $(seq 1 5); do
    curl -fsSL -o "$out" "$url" && return 0
    warn "download failed ($i/5): $url"; sleep 3
  done
  return 1
}

# -- 0. Submodule branches (match macOS prepare.sh: switch each submodule to the K3S branch) -
# Mirrors prepare.sh so Linux hosts pin the same submodule branch the stack is built against.
# SKIP in CI: actions/checkout already pins every submodule to the superproject commit, so
# forcing them onto the moving k3s branch is both unnecessary and wrong (it would swap the
# code under test to branch tips). CI sets SKIP_SUBMODULE_BRANCHES=1.
if [ "${SKIP_SUBMODULE_BRANCHES:-0}" = 1 ]; then
  info "submodule branch switch skipped (SKIP_SUBMODULE_BRANCHES=1; submodules already pinned)"
else
export SUBMODULE_BRANCH
export ROOT
log "submodule branches"
git -C "$ROOT" submodule sync --recursive
git -C "$ROOT" submodule init
git -C "$ROOT" submodule status --recursive | awk '/^-/{print $2}' | while read -r submodule_path; do
  git -C "$ROOT" submodule update --init --recursive -- "$submodule_path"
done
missing_file="$ROOT/.missing-submodule-branches"
dirty_file="$ROOT/.dirty-submodule-branches"
rm -f "$missing_file" "$dirty_file"
trap 'rm -f "$missing_file" "$dirty_file"' EXIT
export missing_file dirty_file
git -C "$ROOT" submodule foreach --recursive '
  echo "  $name -> $SUBMODULE_BRANCH"
  git ls-remote --exit-code --heads origin "$SUBMODULE_BRANCH" >/dev/null
  ls_remote_status=$?
  case "$ls_remote_status" in
    0) ;;
    2)
      echo "$name" >> "$missing_file"
      echo "  missing origin/$SUBMODULE_BRANCH"
      exit 0
      ;;
    *)
      echo "  failed to check origin/$SUBMODULE_BRANCH"
      exit "$ls_remote_status"
      ;;
  esac

  git fetch origin "$SUBMODULE_BRANCH"
  checkout_log="$(mktemp)"
  if git show-ref --verify --quiet "refs/heads/$SUBMODULE_BRANCH"; then
    git checkout -q "$SUBMODULE_BRANCH" >"$checkout_log" 2>&1
    checkout_status=$?
  else
    git checkout -q -b "$SUBMODULE_BRANCH" --track "origin/$SUBMODULE_BRANCH" >"$checkout_log" 2>&1
    checkout_status=$?
  fi
  if [ "$checkout_status" -ne 0 ]; then
    echo "$name" >> "$dirty_file"
    echo "  could not switch to $SUBMODULE_BRANCH; clean or stash local changes"
    rm -f "$checkout_log"
    exit 0
  fi
  rm -f "$checkout_log"
  git pull --ff-only --quiet origin "$SUBMODULE_BRANCH"
'
if [ -s "$dirty_file" ]; then
  dirty_submodule_branches="$(cat "$dirty_file")"
  die "could not switch submodule(s) to $SUBMODULE_BRANCH: ${dirty_submodule_branches//$'\n'/, }"
fi
if [ -s "$missing_file" ]; then
  missing_submodule_branches="$(cat "$missing_file")"
  die "missing origin/$SUBMODULE_BRANCH branch in submodule(s): ${missing_submodule_branches//$'\n'/, }"
fi
fi

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
  $SUDO apt-get update -qq || die "apt update failed (allow security.ubuntu.com, archive.ubuntu.com)"
  $SUDO apt-get install -y -qq postgresql-client || die "postgresql-client install failed"
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
