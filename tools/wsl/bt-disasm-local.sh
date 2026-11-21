#!/bin/bash
# Print the disassembly of the local bluetoothd at one or more vmaddrs, with the
# function stubs and string literals resolved. The full listing is generated once
# into /tmp/bt.dis and reused; the file is byte-identical to the device's binary.
#
# Usage: bt-disasm-local.sh ADDRESS [COUNT]
# ADDRESS is a vmaddr (0x1000f3b44) or the crash offset (0xf3b44), which is
# taken relative to __TEXT at 0x100000000.
set -u
BIN=${BT_BIN:-/root/btbin/iOSRoot/usr/sbin/bluetoothd}
ADDR=${1:?usage: bt-disasm-local.sh ADDRESS [COUNT]}
COUNT=${2:-18}

if [ ! -s /tmp/bt.dis ]; then
	echo "== generating /tmp/bt.dis (once)" >&2
	llvm-objdump --macho -d "$BIN" > /tmp/bt.dis 2>/dev/null || exit 1
fi

case "$ADDR" in
0x100*) want=$((ADDR)) ;;
0x*) want=$((0x100000000 + ADDR)) ;;
*) want=$((0x100000000 + ADDR)) ;;
esac
hex=$(printf '%x' "$want")
line=$(grep -n -m1 "^ *$hex:" /tmp/bt.dis | cut -d: -f1)
if [ -z "$line" ]; then
	echo "no disassembly at $hex" >&2
	exit 1
fi
echo "== $hex"
sed -n "${line},$((line + COUNT))p" /tmp/bt.dis
