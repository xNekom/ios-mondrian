#!/bin/bash
# One boot, both questions: do the switch knobs draw, and does Bluetooth
# discovery reach the controller?
#
# The open-file path launches an app but does not bring it to the front
# (measured 2026-11-21: `MONDRIAN OPEN: com.apple.Preferences -> 1`, no
# present, the panel kept the home screen), so this drives the real path: a
# tap on the Settings icon and a tap on the Bluetooth row.
#
# Usage: tools/wsl/verify-ui-bt.sh [--no-push]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
PUSH=1
[ "${1:-}" = "--no-push" ] && PUSH=0

bash tools/wsl/attach.sh || exit 1

# The bridge's off marker survives reboots; a run that measures the knob has
# to remove it or the app keeps its CGImages.
$RING del /private/var/vm/mondrian-layercsurf-off >/dev/null 2>&1 || true

if [ "$PUSH" = 1 ]; then
	$RING wfile /private/var/vm/mondrian-layer-bridge.dylib \
		out/gpu/mondrian-layer-bridge.dylib || exit 1
	$RING wfile /private/var/vm/mondrian-ui-hook.dylib \
		out/gpu/mondrian-ui-hook.dylib || exit 1
fi

$RING respring
$RING wait 30
$RING bl 1024

# The icon is at panel 200,764 and the Bluetooth row at 720,1116; both were
# measured with the panel capture, which is half scale.
$RING tap 200 764
$RING wait 6
$RING tap 720 1116
$RING wait 4

$RING screen out/ui-bt.png || exit 1
$RING dump out/ui-bt.txt || exit 1

echo "== kernel"
grep -a -m1 'Darwin Kernel Version' out/ui-bt.txt
echo "== app bridge"
grep -a 'MONDRIAN BRIDGE\[.*loaded in Preferences' out/ui-bt.txt | tail -1
grep -a 'contents surface for\|image content got a surface' out/ui-bt.txt | tail -4
echo "== knob surface"
grep -a '129x129' out/ui-bt.txt | tail -6
echo "== server zero copy (must be absent after the respring)"
grep -a 'backboardd create.*129x129.*fmt 0x0' out/ui-bt.txt | tail -2
echo "== presentation"
grep -a 'MONDRIAN FB: present' out/ui-bt.txt | tail -2
grep -a 'MONDRIAN FB: panel' out/ui-bt.txt | tail -1
echo "== assert and crash"
grep -a -c 'Assertion failure in' out/ui-bt.txt
grep -a 'CRASH SpringBoard' out/ui-bt.txt | tail -2
echo "== bluetooth power"
grep -a 'BTPOWER: powered after' out/ui-bt.txt | tail -2
echo "== LE scan traffic"
grep -a 'BTCTL: tx' out/ui-bt.txt | grep -aE '0b 20|02 20|01 04 01' | tail -6
grep -a 'BTCTL: rx' out/ui-bt.txt | grep -a '04 3e' | tail -4
echo "== panel and ring are in out/ui-bt.png and out/ui-bt.txt"
