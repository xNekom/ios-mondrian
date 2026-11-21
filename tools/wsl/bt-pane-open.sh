#!/bin/bash
# Open Settings through LaunchServices instead of hunting for its icon: the UI
# hook's run_watcher opens the app-prefs URL when /private/var/vm/bt-openpane
# exists (bluetooth_open_pane in tools/mondrian-ui-hook.m), one URL form per
# tick, and logs each attempt to the shim power log. The icon's position moves
# between boots, so a tap is the wrong primary path.
#
# Usage: bt-pane-open.sh [WAIT]
# Prints the BTPANE verdicts and writes out/bt-pane-open.png.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
WAIT=${1:-12}
MARK=/private/var/vm/bt-openpane

bash tools/wsl/attach.sh || exit 1
: > out/bt-openpane.mark
$RING wfile "$MARK" out/bt-openpane.mark >/dev/null
echo "== marker written; waiting ${WAIT}s for SpringBoard's run_watcher"
$RING wait "$WAIT" >/dev/null
$RING screen out/bt-pane-open.png >/dev/null
bash tools/wsl/bt-power-log.sh >/dev/null 2>&1
echo "== launch attempts"
grep -a 'BTPANE' out/bt-power.log | tail -8
$RING del "$MARK" >/dev/null
echo "== pane: out/bt-pane-open.png"
