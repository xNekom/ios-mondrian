#!/bin/bash
# Does the daemon hold the device name? Deletes the append-only power log,
# restarts bluetoothd so the device hook runs in a fresh process, lets the open
# pane discover for a while, then prints the hook's lines: `reportDeviceFound`
# and `classicDeviceFound` with the object's name and address.
#
# Usage: bt-device-probe.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
LOG=/private/var/mobile/Library/Preferences/mondrian-bt-power.log

bash tools/wsl/attach.sh || exit 1
$RING del "$LOG" >/dev/null 2>&1
$RING dump /tmp/bt-dev-before.txt >/dev/null
pid=$(grep -a 'BTCTL: connected' /tmp/bt-dev-before.txt |
	sed -n 's/.*pid \([0-9]*\).*/\1/p' | tail -1)
echo "== restart bluetoothd (pid ${pid:-none})"
if [ -n "${pid:-}" ]; then
	$RING kill "$pid"
	$RING wait 25
fi

: > out/bt-device.log
off=0
while [ "$off" -lt 60000 ]; do
	$RING rf "$LOG" "$off" 1000 > /tmp/bt-dev-chunk.bin
	if head -c 2 /tmp/bt-dev-chunk.bin | grep -q '^rf'; then
		break
	fi
	n=$(wc -c < /tmp/bt-dev-chunk.bin)
	cat /tmp/bt-dev-chunk.bin >> out/bt-device.log
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== $(wc -c < out/bt-device.log) bytes"
grep -a 'DeviceFound\|h4:' out/bt-device.log | tail -12
