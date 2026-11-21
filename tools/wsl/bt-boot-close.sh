#!/bin/bash
# Full-ring view of bluetoothd this boot: connection pids, exit lines, and the
# last HCI exchange before the newest exit.
set -u
cd /mnt/c/Users/Pedro/Documents/GitHub/ios-mondrian || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING dump out/bt-current.txt || exit 1

echo "== connects"
grep -a 'BTCTL: connected' out/bt-current.txt | tail -8
echo "== exits"
grep -a 'exit bluetoothd' out/bt-current.txt | tail -8
echo "== count"
grep -a -c 'exit bluetoothd' out/bt-current.txt
echo "== context before the last exit"
line=$(grep -a -n 'exit bluetoothd' out/bt-current.txt | tail -1 | cut -d: -f1)
if [ -n "$line" ]; then
	from=$((line > 24 ? line - 24 : 1))
	sed -n "${from},${line}p" out/bt-current.txt
fi
echo "== last HCI lines"
grep -a 'BTCTL: tx\|BTCTL: rx' out/bt-current.txt | tail -12
