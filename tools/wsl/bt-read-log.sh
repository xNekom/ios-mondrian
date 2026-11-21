#!/bin/bash
# Pull a shim log from the phone to a local file. The shim writes several
# append-only logs under /private/var/mobile/Library/Preferences (power, exit,
# open trace); reading one is the same windowed `rf` loop every time.
#
# Usage: bt-read-log.sh PHONE-PATH [OUT]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
LOG=${1:?usage: bt-read-log.sh PHONE-PATH [OUT]}
OUT=${2:-out/bt-log.txt}
mkdir -p "$(dirname "$OUT")"

bash tools/wsl/attach.sh || exit 1
: > "$OUT"
off=0
while [ "$off" -lt 400000 ]; do
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
echo "== $(wc -c < "$OUT") bytes in $OUT"
