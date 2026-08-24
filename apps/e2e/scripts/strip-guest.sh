#!/usr/bin/env bash
# Strip heavy guest apps to free emulator RAM/CPU (issue #23; research doc 24).
#
# Single source of truth for the strip list. Called from TWO places:
#   1. The workflow's "generate stripped AVD" step (route 1, research doc 24): boot a
#      fresh AVD once, run this, shut down. `pm disable-user` state persists in
#      /data/system/users/0/package-restrictions.xml, and AOSP 14 confirms disabled
#      packages are fully DORMANT on the next cold boot (no BOOT_COMPLETED, no jobs,
#      no process start). The AVD dir is then cached, so every later boot is
#      pre-stripped - the boot-time churn of these apps never happens.
#   2. run-emulator-e2e.sh (belt-and-suspenders): re-applies at test time; a no-op
#      when the cached pre-stripped AVD is in use.
#
# KEEP GMS core (com.google.android.gms - the .local build needs Firebase + fused
# location for the capture-screen GPS gate), the launcher, webview, and TTS/a11y.
# E2E_STRIP_PKGS overrides the default set (space-separated). The workflow's AVD
# cache key hashes THIS FILE, so editing the list invalidates the cached AVD.

STRIP_DEFAULT="com.google.android.gm com.google.android.apps.messaging com.google.android.apps.photos com.google.android.apps.maps com.google.android.youtube com.google.android.googlequicksearchbox com.google.android.syncadapters.contacts com.google.android.ims com.android.chrome com.google.android.calendar com.google.android.apps.docs com.google.android.videos com.google.android.deskclock com.google.android.apps.wellbeing"
STRIP_PKGS="${E2E_STRIP_PKGS:-$STRIP_DEFAULT}"
echo "== stripping heavy guest packages (issue #23 headroom) =="
for pkg in $STRIP_PKGS; do
  if adb shell pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
    echo "  disabled $pkg"; adb shell am force-stop "$pkg" >/dev/null 2>&1 || true
  else
    echo "  (skip $pkg: absent or not disableable)"
  fi
done
