#!/bin/bash
# Test a rebuilt app bridge without a respring: the bridge is read when the
# app execs, so pushing it, killing Preferences and tapping its icon is enough.
# A respring is not usable here: SpringBoard stays at its spinner and the
# poster extensions crash with check-in timeouts (measured 2026-11-21).
#
# Usage: tools/wsl/verify-knob-relaunch.sh [--no-push]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
PUSH=1
[ "${1:-}" = "--no-push" ] && PUSH=0

bash tools/wsl/attach.sh || exit 1
$RING bl 1024
$RING del /private/var/vm/mondrian-layercsurf-off >/dev/null 2>&1 || true

if [ "$PUSH" = 1 ]; then
	$RING wfile /private/var/vm/mondrian-layer-bridge.dylib \
		out/gpu/mondrian-layer-bridge.dylib || exit 1
fi

$RING dump /tmp/knob-before.txt
pid=$(grep -a 'loaded in Preferences' /tmp/knob-before.txt |
	sed -n 's/.*MONDRIAN BRIDGE\[\([0-9][0-9]*\)\]: loaded in Preferences.*/\1/p' |
	tail -1)
if [ -n "$pid" ]; then
	echo "kill Preferences $pid"
	$RING kill "$pid"
	$RING wait 2
fi

# The icon is at panel 200,764; the Bluetooth row at 720,1116.
$RING tap 200 764
$RING wait 6
$RING tap 720 1116
$RING wait 4

$RING screen out/knob-relaunch.png || exit 1
$RING dump out/knob-relaunch.txt || exit 1

echo "== bridge load"
grep -a 'loaded in Preferences' out/knob-relaunch.txt | tail -2
echo "== callers"
grep -a 'contents .* for \|caller' out/knob-relaunch.txt | tail -8
echo "== knob"
grep -a '129x129' out/knob-relaunch.txt | tail -8
echo "== server zero copy"
grep -a 'backboardd create.*129x129.*fmt 0x0' out/knob-relaunch.txt | tail -2
echo "== assert and crash"
grep -a -c 'Assertion failure in' out/knob-relaunch.txt
grep -a 'CRASH SpringBoard' out/knob-relaunch.txt | tail -2
echo "== panel and ring are in out/knob-relaunch.png and out/knob-relaunch.txt"
