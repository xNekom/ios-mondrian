#!/bin/bash
# Does the daemon stay up once the scan-parameter reconfiguration is answered?
# One boot answers it: open the Bluetooth pane (that is what turns LE scanning
# on), then compare two dumps a minute apart. A stable daemon keeps one pid and
# stops printing `exit bluetoothd`; `0x200b reconfig answered` shows the new
# branch ran at least once.
#
# Usage: verify-bt-stable.sh [ICON_X ICON_Y ROW_X ROW_Y]
# The defaults are the Settings icon and the Bluetooth row measured on the home
# screen; confirm them on the boot's own capture before trusting a run that
# never opened the pane.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
ICON_X=${1:-205}
ICON_Y=${2:-780}
ROW_X=${3:-720}
ROW_Y=${4:-1112}

bash tools/wsl/attach.sh || exit 1
$RING bl 1024
$RING wait 20

echo "== open Settings > Bluetooth ($ICON_X,$ICON_Y then $ROW_X,$ROW_Y)"
$RING tap "$ICON_X" "$ICON_Y"
$RING wait 8
$RING tap "$ROW_X" "$ROW_Y"
$RING wait 10
$RING screen out/bt-stable-pane.png

echo "== first sample"
$RING dump out/bt-stable-1.txt
grep -a 'BTCTL: connected' out/bt-stable-1.txt | tail -1
echo "-- exits so far"
grep -a -c 'exit bluetoothd' out/bt-stable-1.txt
echo "-- pane wrote $($RING wait 0 2>/dev/null; true)"

echo "== a minute later"
$RING wait 60
$RING dump out/bt-stable-2.txt
echo "-- pid now"
grep -a 'BTCTL: connected' out/bt-stable-2.txt | tail -1
echo "-- exits now"
grep -a -c 'exit bluetoothd' out/bt-stable-2.txt
echo "-- newest exits"
grep -a 'exit bluetoothd' out/bt-stable-2.txt | tail -3
echo "-- scan reconfigurations answered"
grep -a -c '0x200b answered' out/bt-stable-2.txt
echo "-- scan enables answered"
grep -a -c '0x200c enable answered' out/bt-stable-2.txt
echo "-- scan disables answered"
grep -a -c '0x200c disable answered' out/bt-stable-2.txt
echo "-- vsc answers"
grep -a -c 'vsc e9/\|vsc e2/' out/bt-stable-2.txt

echo "== crash churn"
grep -a -c 'CRASH locationd' out/bt-stable-2.txt

echo "== pane now"
$RING screen out/bt-stable-pane-late.png
