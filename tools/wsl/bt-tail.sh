#!/bin/bash
# Read the tail of a file on the phone. `rf` answers with an "rf ..." error line
# once the offset is past the end, so the size is found by probing, and then the
# last KB are fetched in chunks. The Bluetooth log is capped and rotated, and the
# interesting lines are always the newest ones.
#
# Usage: bt-tail.sh REMOTE-PATH LOCAL-OUT [BYTES]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
REMOTE=${1:?usage: bt-tail.sh REMOTE-PATH LOCAL-OUT [BYTES]}
OUT=${2:?}
WANT=${3:-16000}

bash tools/wsl/attach.sh || exit 1

# Largest power-of-two offset that still answers, then refine by 32 KiB.
size=0
for off in 1048576 524288 262144 131072 65536 32768 16384 8192 4096 2048 1024 0; do
	$RING rf "$REMOTE" "$off" 8 > /tmp/tail-probe.bin 2>/dev/null
	if ! head -c 2 /tmp/tail-probe.bin | grep -q '^rf'; then
		size=$off
		break
	fi
done
echo "== probe says at least $size bytes"
off=$((size > WANT ? size - WANT : 0))
: > "$OUT"
while :; do
	$RING rf "$REMOTE" "$off" 1000 > /tmp/tail-chunk.bin 2>/dev/null
	if head -c 2 /tmp/tail-chunk.bin | grep -q '^rf'; then
		break
	fi
	cat /tmp/tail-chunk.bin >> "$OUT"
	[ "$(wc -c < /tmp/tail-chunk.bin)" -lt 1000 ] && break
	off=$((off + 1000))
done
echo "== $(wc -c < "$OUT") bytes to $OUT"
