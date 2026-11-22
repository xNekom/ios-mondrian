#!/bin/bash
# Tap the Settings icon without touching the backlight. Every script that calls
# `bl 1024` first issues a synchronous DSI brightness write, and the ring shows
# the compositor stalling (rate 1 frame in ~17 s) right after one; a launch that
# stalls that long is killed before its first frame.
#
# Usage: ui-open-settings-plain.sh [OUT.png]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
OUT=${1:-out/plain-settings.png}

bash tools/wsl/attach.sh || exit 1
$RING key 3 down >/dev/null; $RING key 3 up >/dev/null
$RING wait 2
$RING tap 202 756 >/dev/null
$RING wait 15
$RING screen "$OUT"
$RING dump out/plain-settings.txt >/dev/null 2>&1
echo "== exec/exit Preferences"
grep -a 'exec Preferences\|exit Preferences' out/plain-settings.txt | tail -4
echo "== rate"
grep -a 'mondrian-gl: rate' out/plain-settings.txt | tail -3
