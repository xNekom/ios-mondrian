#!/bin/bash
# Does the Settings > Bluetooth switch follow a drag? The same gesture toggles
# Control Center's "Access Within Apps" (tools/wsl/verify-local-switch.sh), so
# a switch that holds On here points at the Bluetooth manager restoring the
# radio, not at the input path. Run with Settings > Bluetooth open: the switch
# spans x 1184..1360 at y 448..504 on the panel (centre 476), and both ends of
# the drag stay inside it.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING bl 1024
$RING screen out/bt-pane-before.png || exit 1

echo "== drag the switch off (1330,476 -> 1200,476 in 150 ms)"
$RING swipe 1330 476 1200 476 150
$RING wait 6
$RING screen out/bt-switch-off.png || exit 1
$RING dump out/bt-switch-off.txt || exit 1

echo "== power lines after off"
grep -a 'BTPOWER: powered\|BTCTL: connected\|BTCTL: disconnected\|BTCTL: tx 4 01 03 0c 00' out/bt-switch-off.txt | tail -8

echo "== drag it back on (1200,476 -> 1330,476 in 150 ms)"
$RING swipe 1200 476 1330 476 150
$RING wait 6
$RING screen out/bt-switch-on.png || exit 1
$RING dump out/bt-switch-on.txt || exit 1

echo "== crash"
grep -a 'CRASH SpringBoard' out/bt-switch-on.txt | tail -2
echo "== panels are in out/bt-pane-before.png, out/bt-switch-off.png, out/bt-switch-on.png"
