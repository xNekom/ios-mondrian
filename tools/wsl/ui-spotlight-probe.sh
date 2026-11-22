#!/bin/bash
# Open Spotlight, capture it, and dump the ring in the same breath, so the
# bridge lines for the result icons are still in the window.
#
# Usage: ui-spotlight-probe.sh [OUT-PREFIX]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
PREF=${1:-out/spot}

bash tools/wsl/attach.sh || exit 1
$RING bl 1024 >/dev/null
$RING key 3 down >/dev/null; $RING key 3 up >/dev/null
$RING wait 2
$RING swipe 720 400 720 1500 260 >/dev/null
$RING wait 4
$RING screen "$PREF.png"
$RING dump "$PREF-ring.txt" >/dev/null 2>&1
echo "capture $PREF.png, ring $PREF-ring.txt"
