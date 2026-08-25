#!/usr/bin/env bash
# submodule-lib.sh - shared submodule setup for prepare.sh (macOS) and prepare-linux.sh.
# Callers define log/info/warn/die and set ROOT and SUBMODULE_BRANCH before sourcing, then call
# setup_submodules. The DEFAULT is PINNED: every submodule is initialized at the gitlink commit
# this superproject commit was validated with (the volunteer path; also a no-op in CI, where
# actions/checkout pins the same commits). FOLLOW_SUBMODULE_BRANCHES=1 is the developer opt-in
# that switches every submodule to the moving $SUBMODULE_BRANCH branch tip instead.

submodules_pin() {
  log "submodules (pinned to the validated commits)"
  git -C "$ROOT" submodule sync --recursive
  git -C "$ROOT" submodule init
  git -C "$ROOT" submodule status --recursive | awk '/^-/{print $2}' | while read -r submodule_path; do
    # The clone of a submodule is a network fetch; ride out transient failures where the
    # caller sourced the retry seam (prepare-linux.sh does; the macOS prepare.sh does not).
    if declare -F retry >/dev/null 2>&1; then
      retry 300 "submodule $submodule_path" \
        git -C "$ROOT" submodule update --init --recursive -- "$submodule_path"
    else
      git -C "$ROOT" submodule update --init --recursive -- "$submodule_path"
    fi
  done
  local drift
  drift="$(git -C "$ROOT" submodule status --recursive | awk '/^\+/{print $2}')"
  [ -z "$drift" ] || warn "submodule(s) ahead of the pinned commit (left untouched): ${drift//$'\n'/, }"
  info "FOLLOW_SUBMODULE_BRANCHES=1 switches submodules to the $SUBMODULE_BRANCH branch (developers only)"
}

submodules_follow_branch() {
  export SUBMODULE_BRANCH
  export ROOT
  log "submodule branches (developer mode: tracking $SUBMODULE_BRANCH)"
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
}

setup_submodules() {
  if [ "${FOLLOW_SUBMODULE_BRANCHES:-0}" = 1 ]; then
    submodules_follow_branch
  else
    submodules_pin
  fi
}
