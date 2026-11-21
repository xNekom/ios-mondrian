#!/bin/bash
# Is the corrupted Control Center tile block reproducible from a clean boot?
# Three captures: Control Center before touching it, right after the Bluetooth
# tile is tapped, and after the sheet is dismissed and reopened. A block that
# appears only in the last one is a composited surface the tile transition left
# behind; one that is already in the first is not this test's.
#
# Usage: verify-cc-draw.sh [ICON_X ICON_Y]
# Nothing here needs Settings; the sheet opens from the top-right edge.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING bl 1024
$RING wait 30

echo "== Control Center, untouched"
$RING swipe 1400 8 1400 1200 200
$RING wait 4
$RING screen out/cc-clean.png || exit 1

echo "== tap the Bluetooth tile"
$RING tap 554 766
$RING wait 4
$RING screen out/cc-bt-tapped.png || exit 1

echo "== dismiss and reopen"
$RING tap 700 1400
$RING wait 3
$RING swipe 1400 8 1400 1200 200
$RING wait 4
$RING screen out/cc-reopened.png || exit 1

echo "== restore the tile (it only stops new connections)"
$RING tap 554 766
$RING wait 2
$RING tap 700 1400
$RING wait 2

$RING dump out/cc-draw.txt >/dev/null
echo "== bluetoothd"
grep -a 'BTCTL: connected' out/cc-draw.txt | tail -1
grep -a -c 'exit bluetoothd' out/cc-draw.txt
echo "== panels are out/cc-clean.png, out/cc-bt-tapped.png, out/cc-reopened.png"
