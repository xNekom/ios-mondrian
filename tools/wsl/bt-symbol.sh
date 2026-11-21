#!/bin/bash
# Resolve offsets from bluetoothd's mach header to the nearest symbol, using the
# phone's own copies of __LINKEDIT: the crash reports `lr bluetoothd + OFFSET`
# and the symbol table says which function that offset belongs to.
#
# Usage: bt-symbol.sh OFFSET [OFFSET ...]
# Each OFFSET is the value the kernel prints after "bluetoothd + " (e.g.
# 0xf3b50). The __TEXT vmaddr is 0x100000000 and its file offset is 0, so the
# file offset equals the crash offset.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
BIN=/usr/sbin/bluetoothd
SYMOFF=0x85d1a8
NSYMS=1427
STROFF=0x864ef0
STRSIZE=0x9a78
TEXT_BASE=0x100000000

pull() {
	local off=$1
	local len=$2
	local out=$3
	local got=0
	: > "$out"
	while [ "$got" -lt "$len" ]; do
		$RING rf "$BIN" $((off + got)) $((len - got)) > /tmp/bt-pull-chunk.bin
		if head -c 2 /tmp/bt-pull-chunk.bin | grep -q '^rf'; then
			echo "missing bytes at $((off + got))" >&2
			return 1
		fi
		n=$(wc -c < /tmp/bt-pull-chunk.bin)
		[ "$n" -eq 0 ] && return 1
		cat /tmp/bt-pull-chunk.bin >> "$out"
		got=$((got + n))
	done
	return 0
}

bash tools/wsl/attach.sh || exit 1
echo "== pulling $(($NSYMS * 16)) bytes of symbols and $STRSIZE bytes of names"
pull "$SYMOFF" $((NSYMS * 16)) out/bt-symtab.bin || exit 1
pull "$STROFF" $((STRSIZE)) out/bt-strtab.bin || exit 1

python3 - "$TEXT_BASE" "$@" <<'PY'
import struct
import sys

base = int(sys.argv[1], 0)
wanted = [int(a, 0) + base for a in sys.argv[2:]]
sym = open('out/bt-symtab.bin', 'rb').read()
strtab = open('out/bt-strtab.bin', 'rb').read()

syms = []
for i in range(0, len(sym), 16):
    strx, n_type, n_sect, n_desc, n_value = \
        struct.unpack('<IBBHQ', sym[i:i + 16])
    if n_value == 0 or strx >= len(strtab):
        continue
    end = strtab.find(b'\0', strx)
    name = strtab[strx:end if end >= 0 else len(strtab)].decode('utf-8', 'replace')
    syms.append((n_value, n_type, n_sect, name))
syms.sort()
print('%d symbols with an address' % len(syms))

for target in wanted:
    below = [s for s in syms if s[0] <= target]
    above = [s for s in syms if s[0] > target]
    if below:
        value, n_type, n_sect, name = below[-1]
        print('%#x -> %s + %#x (type %#x sect %d)' %
              (target, name, target - value, n_type, n_sect))
    else:
        print('%#x -> (before the first symbol)' % target)
    if above:
        print('        next: %s at %#x' % (above[0][3], above[0][0]))
PY
