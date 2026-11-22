#!/bin/bash
# Capture the Settings root (and optionally one pane) after a home-screen reset.
#
# Usage: ui-settings-shot.sh OUT.png [TAP_X TAP_Y] [WAIT_SECONDS]
# With no tap, the root list is captured; with a tap, that row opens first.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
OUT=${1:?usage: ui-settings-shot.sh OUT.png [TAP_X TAP_Y] [WAIT]}
X=${2:-}
Y=${3:-}
WAIT=${4:-25}

bash tools/wsl/attach.sh || exit 1
$RING bl 1024 >/dev/null
$RING key 3 down >/dev/null; $RING key 3 up >/dev/null
$RING wait 2
$RING tap 202 756 >/dev/null      # Settings icon (panel pixels, not the capture)
$RING wait "$WAIT"
if [ -n "$X" ]; then
	$RING tap "$X" "$Y" >/dev/null
	$RING wait 6
fi
$RING screen "$OUT"
