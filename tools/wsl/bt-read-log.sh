#!/bin/bash
# Pull a shim log from the phone to a local file. The shim writes several
# append-only logs under /private/var/mobile/Library/Preferences (power, exit,
# open trace); reading one is the same windowed `rf` loop every time.
#
# Usage: bt-read-log.sh PHONE-PATH [OUT] [START]
#
# The power log passes the old 400 KB cap, and a pull that stops there drops
# exactly the newest lines a session needs (measured 2026-11-21: pid 815 wrote
# nothing in the copy while the phone had it). START skips the part already
# read; the loop itself stops at EOF, not at a fixed size.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
LOG=${1:?usage: bt-read-log.sh PHONE-PATH [OUT] [START]}
OUT=${2:-out/bt-log.txt}
START=${3:-0}
mkdir -p "$(dirname "$OUT")"

bash tools/wsl/attach.sh || exit 1
: > "$OUT"
off=$START
while :; do
	$RING rf "$LOG" "$off" 1000 > /tmp/bt-read-chunk.bin
	if head -c 2 /tmp/bt-read-chunk.bin | grep -q '^rf'; then
		[ "$off" = 0 ] && echo "missing $LOG" >&2
		break
	fi
	n=$(wc -c < /tmp/bt-read-chunk.bin)
	cat /tmp/bt-read-chunk.bin >> "$OUT"
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== $(wc -c < "$OUT") bytes in $OUT from $START"
