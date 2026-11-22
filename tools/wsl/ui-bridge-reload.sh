#!/bin/bash
# Push a rebuilt app bridge and reload it through a respring, then prove the
# Settings switch still draws. A respring restarts backboardd and every client,
# which is what makes a pushed dylib take effect; the phone lands on the lock
# screen, so the unlock comes first.
#
# Usage: ui-bridge-reload.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING wfile /private/var/vm/mondrian-layer-bridge.dylib \
	out/gpu/mondrian-layer-bridge.dylib || exit 1
$RING respring || exit 1
$RING wait 25
$RING bl 1024 >/dev/null
$RING key 0 down >/dev/null; $RING key 0 up >/dev/null
$RING wait 1
$RING key 0 down >/dev/null; $RING key 0 up >/dev/null
$RING wait 2
$RING swipe 720 3120 720 700 500 >/dev/null
$RING wait 4

$RING tap 202 756 >/dev/null
$RING wait 25
$RING screen out/bridge-reload.png || exit 1
$RING dump out/bridge-reload.txt >/dev/null 2>&1

echo "== bridge load"
grep -a 'MONDRIAN BRIDGE\[' out/bridge-reload.txt |
	grep -a 'loaded in Preferences' | tail -2
echo "== zero copies of the knob"
grep -a 'backboardd create.*129x129.*fmt 0x0' out/bridge-reload.txt | tail -2
echo "== assert and crash"
grep -a -c 'Assertion failure in' out/bridge-reload.txt
grep -a 'CRASH SpringBoard\|CRASH Preferences' out/bridge-reload.txt | tail -2
