#!/bin/bash
# The documented cure for "the home screen draws but taps stop launching apps":
# sleep, wake, unlock, then launch. Each step is captured, so a step that did not
# happen is visible instead of being read as a dead icon.
#
# Usage: ui-wake-cycle.sh [OUT-PREFIX]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
PREF=${1:-out/wake}

bash tools/wsl/attach.sh || exit 1
$RING key 0 down >/dev/null; $RING key 0 up >/dev/null
$RING wait 3
$RING key 0 down >/dev/null; $RING key 0 up >/dev/null
$RING wait 3
$RING screen "$PREF-lock.png"
$RING swipe 720 3140 720 300 700 >/dev/null
$RING wait 4
$RING screen "$PREF-home.png"
$RING tap 202 756 >/dev/null
$RING wait 15
$RING screen "$PREF-settings.png"
$RING dump "$PREF-ring.txt" >/dev/null 2>&1
echo "== exec/exit Preferences"
grep -a 'exec Preferences\|exit Preferences' "$PREF-ring.txt" | tail -4
