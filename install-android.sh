#!/usr/bin/env bash
# Install pencil.koplugin into KOReader on an Android device over adb.
#
# Usage: ./install-android.sh [adb-serial-or-host:port]
#
# Needs adb (Android platform-tools) on PATH or in ~/Android/Sdk, USB or
# wireless debugging enabled on the device, and KOReader opened once so
# /sdcard/koreader exists. Only the plugin folder is copied; nothing else on
# the device is touched.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ADB="$(command -v adb || true)"
[ -n "$ADB" ] || ADB="$HOME/Android/Sdk/platform-tools/adb"
[ -x "$ADB" ] || { echo "adb not found; install Android platform-tools" >&2; exit 1; }
T=${1:-}
A() { if [ -n "$T" ]; then "$ADB" -s "$T" "$@"; else "$ADB" "$@"; fi; }

echo "== KOReader on device"
A shell dumpsys package org.koreader.launcher 2>/dev/null | grep -m1 versionName \
  || { echo "KOReader not found on the device" >&2; exit 1; }
DATA=/sdcard/koreader
A shell test -d "$DATA" || { echo "$DATA missing: open KOReader once first" >&2; exit 1; }

echo "== pushing plugin to $DATA/plugins/pencil.koplugin"
A shell mkdir -p "$DATA/plugins"
A shell rm -rf "$DATA/plugins/pencil.koplugin"
A push "$HERE/pencil.koplugin" "$DATA/plugins/pencil.koplugin" >/dev/null
A shell ls "$DATA/plugins/pencil.koplugin"
echo "== done. Restart KOReader, then: top menu > More tools > Pencil > Enabled"
echo "   KOReader's log on the device: $DATA/crash.log (search for Pencil)"
