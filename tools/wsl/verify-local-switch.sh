#!/bin/bash
# A 0 ms tap does not move a UISwitch; a 120 ms drag whose ends stay inside the
# control does, and the new state sticks. Run with Settings > Control Center
# open: this switch ("Access Within Apps") is a local preference with no daemon
# behind it, so it isolates the input path from any service.
#
# Measured panel coordinates (1440x3200) in that pane: the switch spans
# x 1184..1360 at y 596..658; the row centre is 626. Settings rows are 108 px
# tall and the list shifts about 50 px when the large title collapses, so aim
# at a row centre and re-read the capture after navigating.
#
# The script toggles twice, so it ends where it started; compare the four
# captures: the tap one matches the first, the two drag ones differ.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING bl 1024

$RING screen out/switch-1-before.png || exit 1

echo "== tap the switch (expected: no change)"
$RING tap 1256 626
$RING wait 3
$RING screen out/switch-2-tap.png || exit 1

echo "== drag it (expected: toggles and stays)"
$RING swipe 1330 626 1200 626 150
$RING wait 3
$RING screen out/switch-3-drag.png || exit 1

echo "== drag it back (expected: returns to the first state)"
$RING swipe 1200 626 1330 626 150
$RING wait 3
$RING screen out/switch-4-back.png || exit 1
$RING dump out/switch.txt || exit 1

echo "== crash"
grep -a 'CRASH SpringBoard' out/switch.txt | tail -2
echo "== panels are out/switch-1-before.png .. out/switch-4-back.png"
