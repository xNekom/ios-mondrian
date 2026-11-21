#!/bin/bash
# Does confirming the Settings > Bluetooth switch's "Turn off Bluetooth?" alert
# stop the controller? The Inquiry is the witness: a real power-off breaks its
# ~16 s cadence. The pane swaps the switch for a spinner during the daemon's
# transitions, so the drag is repeated before the alert is expected.
#
# Run with Settings > Bluetooth open; out/bt-cycle-before.png confirms the pane.
# Measured 2026-11-21: the alert appears, Turn Off dims the title and leaves a
# spinner, and the Inquiry cadence does not break (this script prints it).
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING bl 1024
$RING screen out/bt-cycle-before.png || exit 1

echo "== drag the switch (three tries, alternating)"
for i in 1 2 3; do
	if [ $((i % 2)) = 1 ]; then
		$RING swipe 1330 476 1200 476 150
	else
		$RING swipe 1200 476 1330 476 150
	fi
	$RING wait 2
done
$RING screen out/bt-cycle-alert.png || exit 1

echo "== Turn Off (a no-op when the alert did not appear)"
$RING tap 922 1784
$RING wait 6
$RING screen out/bt-cycle-off.png || exit 1
$RING dump out/bt-cycle-off.txt || exit 1

echo "-- inquiry seconds around the off"
awk '
  /SMP t=/ { for (i = 1; i <= NF; i++) if ($i ~ /^t=[0-9]+s$/) {
      t = $i; sub("t=", "", t); sub("s", "", t); cur = t } }
  /BTCTL: tx 9 01 01 04/ { print cur }
' out/bt-cycle-off.txt | tail -10

echo "== drag it back on"
$RING swipe 1200 476 1330 476 150
$RING wait 8
$RING screen out/bt-cycle-on.png || exit 1
$RING dump out/bt-cycle-on.txt || exit 1

echo "-- inquiry after the on"
awk '
  /SMP t=/ { for (i = 1; i <= NF; i++) if ($i ~ /^t=[0-9]+s$/) {
      t = $i; sub("t=", "", t); sub("s", "", t); cur = t } }
  /BTCTL: tx 9 01 01 04/ { print cur }
' out/bt-cycle-on.txt | tail -4
echo "== panels are out/bt-cycle-before.png, out/bt-cycle-alert.png, out/bt-cycle-off.png, out/bt-cycle-on.png"
