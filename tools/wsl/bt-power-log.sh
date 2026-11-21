#!/bin/bash
# Read the shim's append-only power log. bluetoothd truncates its main log on
# every start, so a message that arrives just before a crash survives only
# here; this is the file that shows what the daemon received when the switch
# was dragged.
#
# Usage: bt-power-log.sh [drag]
# "drag" performs the switch drag first (panel coordinates of the Bluetooth
# pane's switch), so the log ends with the message the action produced.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
LOG=/private/var/mobile/Library/Preferences/mondrian-bt-power.log
DRAG=${1:-}

bash tools/wsl/attach.sh || exit 1
if [ "$DRAG" = drag ]; then
	echo "== drag the switch"
	$RING swipe 1330 478 1200 478 150
	$RING wait 10
fi

: > /tmp/bt-power.txt
off=0
while [ "$off" -lt 40000 ]; do
	$RING rf "$LOG" "$off" 1000 > /tmp/bt-power-chunk.txt
	if head -c 2 /tmp/bt-power-chunk.txt | grep -q '^rf'; then
		break
	fi
	n=$(wc -c < /tmp/bt-power-chunk.txt)
	cat /tmp/bt-power-chunk.txt >> /tmp/bt-power.txt
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== $(wc -c < /tmp/bt-power.txt) bytes"
cp /tmp/bt-power.txt out/bt-power.log
tail -24 /tmp/bt-power.txt
