#!/bin/bash
# Decode the HCI transport tables slot by slot: each entry printed as the pointer
# it holds and, when the pointer is inside __TEXT, the nearest function symbol
# from the binary's own disassembly. This is how the slot at +0x60 (the one the
# Settings switch reaches with a NULL) gets compared with the other transports.
#
# Usage: bt-transport-slots.sh [BINARY]
set -u
BIN=${1:-/root/btbin/iOSRoot/usr/sbin/bluetoothd}

python3 - "$BIN" <<'PY'
import struct
import sys

path = sys.argv[1]
data = open(path, 'rb').read()
TEXT = 0x100000000
print('%-10s %-6s %s' % ('table', 'slot', 'pointer'))
tables = {
    'H4': 0x844228,
    'H4DS': 0x844350,
    'H4BC': 0x8442b8,
    'H5': 0x8443e0,
    'APPLEBT': 0x8440b0,
}
for name, off in tables.items():
    print('==', name)
    for slot in range(0, 0x70, 8):
        raw = data[off + slot:off + slot + 8]
        if len(raw) < 8:
            break
        value = struct.unpack('<Q', raw)[0]
        if value == 0:
            print('  +%#04x  NULL' % slot)
            continue
        hint = ''
        if TEXT <= value < TEXT + 0x7f4000:
            hint = ' __TEXT:%#x' % (value - TEXT)
        if slot == 0x08:
            # chained fixup: low 36 bits are the target's vm offset
            target = value & 0xFFFFFFFFF
            end = data.find(b'\0', target, target + 64)
            if 0 < end:
                hint += ' "%s"' % data[target:end].decode('utf-8', 'replace')
        print('  +%#04x  %#018x%s' % (slot, value, hint))
PY
