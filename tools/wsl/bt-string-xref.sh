#!/bin/bash
# Find where bluetoothd loads a literal string: llvm-objdump annotates the
# instruction that materialises it ("literal pool for: \"...\""), so matching
# the string finds the function that logs or branches on it.
#
# Usage: bt-string-xref.sh TEXT [BINARY]
set -u
BIN=${2:-/root/btbin/iOSRoot/usr/sbin/bluetoothd}
TEXT=${1:?usage: bt-string-xref.sh TEXT [BINARY]}

if [ ! -s /tmp/bt.dis ]; then
	llvm-objdump --macho -d "$BIN" > /tmp/bt.dis 2>/dev/null || exit 1
fi
grep -n "literal pool for: \"$TEXT" /tmp/bt.dis | head -8
