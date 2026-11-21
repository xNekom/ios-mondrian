#!/bin/bash
# The last HCI exchange before bluetoothd exits names the command it is waiting
# for: the control logs every packet, and the exit leaves its own line in the
# ring.
set -u
cd /mnt/c/Users/Pedro/Documents/GitHub/ios-mondrian || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING dump out/bt-exit-now.txt || exit 1

line=$(grep -a -n 'exit bluetoothd' out/bt-exit-now.txt | tail -1 | cut -d: -f1)
echo "== exit at line $line"
[ -n "$line" ] || exit 1
from=$((line > 20 ? line - 20 : 1))
sed -n "${from},${line}p" out/bt-exit-now.txt
echo "== last 12 HCI packets"
grep -a 'BTCTL: tx\|BTCTL: rx' out/bt-exit-now.txt | tail -12
