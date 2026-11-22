#!/bin/bash
# Reload Preferences with the pushed bridge, open Settings, and dump its view
# tree. This is the end-to-end check of the app-side dump: a process that can be
# restarted safely, and a screen whose switch knob is the reference.
#
# A 30 s wait after the tap loses the dump: the phone locks and the app's windows
# go away, which reads as "0 windows" (measured 2026-11-22). The list is
# scrolled a little before arming to keep it awake.
#
# Usage: ui-deep-settings.sh [NUMBER]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
N=${1:-6}

bash tools/wsl/attach.sh || exit 1
$RING wfile /private/var/vm/mondrian-layer-bridge.dylib \
	out/gpu/mondrian-layer-bridge.dylib >/dev/null || exit 1

printf 'kill Preferences\n' > out/spot-kill.txt
$RING wfile /private/var/vm/bt-poke out/spot-kill.txt >/dev/null || exit 1
$RING wait 4
$RING key 3 down >/dev/null; $RING key 3 up >/dev/null
$RING wait 2
$RING tap 202 756 >/dev/null
$RING wait 12
$RING swipe 700 2100 700 1900 250 >/dev/null
$RING wait 1

bash tools/wsl/ui-bridge-alive.sh 4 >/dev/null 2>&1
pid=$(grep -a '^Preferences pid' out/bridge-alive.log | tail -1 |
	sed -n 's/^Preferences pid \([0-9][0-9]*\): loaded/\1/p')
echo "== Preferences pid ${pid:-none}"
if [ -z "${pid:-}" ]; then
	echo "no Preferences load line: the bridge did not reach it" >&2
	exit 1
fi
bash tools/wsl/ui-deep-app-pull.sh "$pid" "$N" |
	head -34
