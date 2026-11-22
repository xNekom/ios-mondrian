#!/bin/bash
# Which processes loaded the bridge, from the bridge itself. One appended line
# per load, written to a file because an app's console output does not reach
# the ring on this port.
#
# Usage: ui-bridge-alive.sh [LINES]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
LOG=/private/var/mobile/Library/Preferences/mondrian-bridge-alive.log

bash tools/wsl/attach.sh || exit 1
: > out/bridge-alive.log
off=0
for _ in $(seq 1 30); do
	$RING rf "$LOG" "$off" 1000 > /tmp/alive-chunk.bin 2>/dev/null
	if head -c 2 /tmp/alive-chunk.bin | grep -q '^rf'; then
		break
	fi
	n=$(wc -c < /tmp/alive-chunk.bin)
	cat /tmp/alive-chunk.bin >> out/bridge-alive.log
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== $(wc -c < out/bridge-alive.log) bytes"
tail -"${1:-12}" out/bridge-alive.log
