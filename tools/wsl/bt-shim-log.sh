#!/bin/bash
# Pull the shim's main log out of the phone. bluetoothd truncates it on every
# start, so it holds the newest daemon only; the append-only power log is the
# one that survives a crash. The name carries a `d` (mondrian-btd.log), which
# is easy to miss and makes the file look absent.
#
# Usage: bt-shim-log.sh [GREP-PATTERN]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
LOG=/private/var/mobile/Library/Preferences/mondrian-btd.log

bash tools/wsl/attach.sh || exit 1
: > out/bt-shim.log
off=0
while [ "$off" -lt 400000 ]; do
	$RING rf "$LOG" "$off" 1000 > /tmp/bt-shim-chunk.bin
	if head -c 2 /tmp/bt-shim-chunk.bin | grep -q '^rf'; then
		break
	fi
	n=$(wc -c < /tmp/bt-shim-chunk.bin)
	cat /tmp/bt-shim-chunk.bin >> out/bt-shim.log
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== $(wc -c < out/bt-shim.log) bytes"
if [ "$#" -gt 0 ]; then
	grep -a -e "$1" out/bt-shim.log | tail -30
else
	tail -40 out/bt-shim.log
fi
