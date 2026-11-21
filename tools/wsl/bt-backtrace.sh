#!/bin/bash
# Print the crash backtrace frames with their surrounding code and any literal
# strings, so each frame can be named by the message it logs. The addresses are
# the ones the kernel prints in the bluetoothd crash line.
#
# Usage: bt-backtrace.sh [ADDR ...]
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ "$#" -eq 0 ]; then
	set -- 0x895d4 0x3c7fb8 0x3ca658 0x3a5bcc
fi
for a in "$@"; do
	echo "=== frame $a"
	bash tools/wsl/bt-disasm-local.sh "$a" 10 || continue
	start=$((a > 0x100 ? a - 0x100 : 0))
	# literal pools in the preceding 256 bytes name the function's work
	hex=$(printf '%x' "$start")
	line=$(grep -n -m1 "^ *$hex:" /tmp/bt.dis | cut -d: -f1)
	[ -z "$line" ] && continue
	sed -n "${line},$((line + 64))p" /tmp/bt.dis | grep 'literal pool for:' | head -3
done
