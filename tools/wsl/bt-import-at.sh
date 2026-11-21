#!/bin/bash
# Map the direct calls of a bluetoothd function to the import each one goes
# through. The binary is stripped of local names, but every __stubs entry has an
# entry in the indirect symbol table, so a `bl` into __stubs resolves to the
# imported function's name: that is how a NULL weak import gets a name.
#
# Usage: bt-import-at.sh OFFSET LENGTH
# OFFSET is the file offset of the function (e.g. 0xe2aac); LENGTH its bytes.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
BIN=/usr/sbin/bluetoothd
OFF=${1:?usage: bt-import-at.sh OFFSET LENGTH}
LEN=${2:?usage: bt-import-at.sh OFFSET LENGTH}
LEN=$((LEN))

pull() {
	local off=$1 len=$2 out=$3 got=0
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
}

bash tools/wsl/attach.sh || exit 1
if [ ! -s out/bt-symtab.bin ] || [ ! -s out/bt-strtab.bin ]; then
	bash tools/wsl/bt-symbol.sh 0 >/dev/null 2>&1 || exit 1
fi
if [ ! -s out/bt-head.bin ]; then
	bash tools/wsl/bt-macho-info.sh >/dev/null 2>&1 || exit 1
fi
pull "$OFF" "$LEN" /tmp/bt-func.bin || exit 1

python3 - "$OFF" <<'PY'
import struct
import subprocess
import sys

func_off = int(sys.argv[1], 0)
text = open('/tmp/bt-func.bin', 'rb').read()
head = open('out/bt-head.bin', 'rb').read()
sym = open('out/bt-symtab.bin', 'rb').read()
strtab = open('out/bt-strtab.bin', 'rb').read()

ncmds = struct.unpack('<I', head[16:20])[0]
off = 32
stubs = None
indirect_off = indirect_count = None
for _ in range(ncmds):
    if off + 8 > len(head):
        break
    cmd, cmdsize = struct.unpack('<II', head[off:off + 8])
    if cmd == 0x19:
        nsects = struct.unpack('<I', head[off + 64:off + 68])[0]
        sec = off + 72
        for _ in range(nsects):
            sectname = head[sec:sec + 16].rstrip(b'\0').decode()
            if sectname == '__stubs':
                addr, size = struct.unpack('<QQ', head[sec + 32:sec + 48])
                reserved1 = struct.unpack('<I', head[sec + 68:sec + 72])[0]
                stubs = (addr, size, reserved1)
            sec += 80
    elif cmd == 0xb:
        vals = struct.unpack('<18I', head[off + 8:off + 8 + 72])
        indirect_off, indirect_count = vals[12], vals[13]
    off += cmdsize

if stubs is None or indirect_off is None:
    raise SystemExit('no __stubs or no LC_DYSYMTAB in the header')

want = 4 * indirect_count
ind = b''
while len(ind) < want:
    r = subprocess.run(['python3', 'tools/usb-ring.py', 'rf',
                        '/usr/sbin/bluetoothd',
                        str(indirect_off + len(ind)),
                        str(min(1000, want - len(ind)))],
                       capture_output=True)
    if not r.stdout:
        break
    ind += r.stdout
print('__stubs %#x size %#x reserved1 %d, indirect %d entries at %#x (got %d bytes)'
      % (stubs[0], stubs[1], stubs[2], indirect_count, indirect_off, len(ind)))

names = {}
for i in range(0, len(ind) - 3, 4):
    sym_index = struct.unpack('<I', ind[i:i + 4])[0]
    if sym_index == 0x80000000 or sym_index * 16 + 16 > len(sym):
        continue
    strx, n_type, n_sect, n_desc, n_value = \
        struct.unpack('<IBBHQ', sym[sym_index * 16:sym_index * 16 + 16])
    end = strtab.find(b'\0', strx)
    names[i // 4] = strtab[strx:end if end >= 0 else len(strtab)].decode('utf-8', 'replace')

stub_base, stub_size, reserved1 = stubs
stub_base &= 0xFFFFFFFF
for i in range(0, len(text) - 3, 4):
    word = struct.unpack('<I', text[i:i + 4])[0]
    if word & 0xFC000000 != 0x94000000:  # BL
        continue
    imm = word & 0x03FFFFFF
    if imm & 0x02000000:
        imm -= 0x04000000
    target = func_off + i + imm * 4
    note = ''
    if stub_base <= target < stub_base + stub_size:
        index = reserved1 + (target - stub_base) // 12
        note = ' -> ' + names.get(index, '(index %d out of range)' % index)
    print('%#x: bl %#x%s' % (func_off + i, target, note))
PY
