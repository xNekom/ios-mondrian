#!/bin/bash
# Read the Mach-O header and load commands of the phone's bluetoothd and print
# the pieces needed to symbolicate a crash offset: the __TEXT mapping, the
# symbol table (if the binary keeps one) and the function-start table.
#
# Usage: bt-macho-info.sh [BYTES]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
BIN=/usr/sbin/bluetoothd
WANT=${1:-8192}

bash tools/wsl/attach.sh || exit 1
: > out/bt-head.bin
off=0
while [ "$off" -lt "$WANT" ]; do
	$RING rf "$BIN" "$off" 1000 > /tmp/bt-head-chunk.bin
	if head -c 2 /tmp/bt-head-chunk.bin | grep -q '^rf'; then
		break
	fi
	n=$(wc -c < /tmp/bt-head-chunk.bin)
	cat /tmp/bt-head-chunk.bin >> out/bt-head.bin
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== $(wc -c < out/bt-head.bin) bytes of $BIN"
python3 - <<'PY'
import struct

data = open('out/bt-head.bin', 'rb').read()
magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = \
    struct.unpack('<IiiIIIII', data[:32])
print('magic %#x filetype %d ncmds %d sizeofcmds %d' %
      (magic, filetype, ncmds, sizeofcmds))
off = 32
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack('<II', data[off:off + 8])
    if cmd == 0x19:
        name = data[off + 8:off + 24].rstrip(b'\0').decode()
        vmaddr, vmsize, fileoff, filesize = \
            struct.unpack('<QQQQ', data[off + 24:off + 56])
        print('SEG %-16s vmaddr %#x fileoff %#x filesize %#x' %
              (name, vmaddr, fileoff, filesize))
    elif cmd == 0x2:
        symoff, nsyms, stroff, strsize = \
            struct.unpack('<IIII', data[off + 8:off + 24])
        print('SYMTAB symoff %#x nsyms %d stroff %#x strsize %#x' %
              (symoff, nsyms, stroff, strsize))
    elif cmd == 0x26:
        dataoff, datasize = struct.unpack('<II', data[off + 8:off + 16])
        print('FUNCSTARTS dataoff %#x datasize %#x' % (dataoff, datasize))
    elif cmd == 0xb:
        print('DYSYMTAB')
    else:
        print('cmd %#x size %d' % (cmd, cmdsize))
    off += cmdsize
PY
