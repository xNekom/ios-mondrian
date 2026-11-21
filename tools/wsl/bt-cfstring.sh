#!/bin/bash
# Read a constant CFString from the phone's bluetoothd by its vmaddr: the object
# is {isa, flags, cstring}, so the third word points at the text. Used to name
# the device-tree property a check reads.
#
# Usage: bt-cfstring.sh VMADDR [BINARY]
set -u
BIN=${2:-/root/btbin/iOSRoot/usr/sbin/bluetoothd}
ADDR=${1:?usage: bt-cfstring.sh VMADDR [BINARY]}

python3 - "$BIN" "$ADDR" <<'PY'
import struct
import sys

path, addr = sys.argv[1], int(sys.argv[2], 0)
if addr >= 0x100000000:
    addr -= 0x100000000
data = open(path, 'rb').read()
words = struct.unpack('<QQQ', data[addr:addr + 24])
print('isa %#x flags %#x text %#x' % words)
text = words[2]
text = text & 0xFFFFFFFFF          # chained fixup: low 36 bits are the target
end = data.find(b'\0', text, text + 128)
print(repr(data[text:end].decode('utf-8', 'replace')))
PY
