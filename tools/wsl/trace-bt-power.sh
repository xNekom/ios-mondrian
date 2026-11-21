#!/bin/bash
# Does the Settings > Bluetooth switch reach MobileBluetooth? The kernel logs
# every synthetic touch as "MONDR USB: touch ...", so that line marks the drag
# in the ring; the BTCTL lines after it say what the manager did with the
# transport -- a close that stays closed is a power-off, a close followed by a
# connect and an HCI Reset is the manager restoring the radio.
#
# Run with Settings > Bluetooth already open and confirmed by a capture: a tap
# that opens the pane can land after the drag if the push is still animating
# (measured 2026-11-21), and the trace then reads the wrong window.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING bl 1024
$RING screen out/bt-trace-before.png || exit 1

echo "== drag the switch off (1330,476 -> 1200,476 in 150 ms)"
$RING swipe 1330 476 1200 476 150
$RING wait 6
$RING screen out/bt-trace-off.png || exit 1
$RING dump out/bt-trace.txt || exit 1

echo "== transport and power events after the drag marker"
awk '/MONDR USB: touch 1330,476/ { start = NR }
     { line[NR] = $0 }
     END { for (i = start; i <= NR; i++) print line[i] }' out/bt-trace.txt |
	grep -a 'BTCTL\|BTPOWER\|MONDR USB: touch' | tail -40
echo "== panel is out/bt-trace-off.png; ring is out/bt-trace.txt"
