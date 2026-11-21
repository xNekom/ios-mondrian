#!/bin/bash
# Disassemble the bluetoothd call site that jumps to NULL when the Bluetooth
# switch is dragged. The kernel's crash line gives `pc 0x0 lr <bluetoothd +
# OFFSET>` and `mh <base>`; the image's mach header sits at the start of
# __TEXT, whose file offset is 0, so the caller's bytes are at file OFFSET.
#
# Usage: bt-callsite.sh OFFSET [BEFORE] [BYTES]
# OFFSET is the LR offset from the crash line (0xf3b50), BEFORE is how much
# context to read before it (default 128), BYTES the window (default 384).
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
BIN=/usr/sbin/bluetoothd
OFF=${1:?usage: bt-callsite.sh OFFSET [BEFORE] [BYTES]}
BEFORE=${2:-128}
BYTES=${3:-384}
START=$((OFF - BEFORE))

bash tools/wsl/attach.sh || exit 1
echo "== header"
$RING rf "$BIN" 0 32 | od -An -tx1 | head -2
echo "== bytes at 0x$(printf '%x' "$START")"
$RING rf "$BIN" "$START" "$BYTES" > /tmp/bt-code.bin
od -An -tx1 /tmp/bt-code.bin | head -4
echo "== disassembly (offsets from 0x$(printf '%x' "$START"))"
python3 - "$START" <<'PY'
import subprocess, sys

start = int(sys.argv[1], 0)
data = open('/tmp/bt-code.bin', 'rb').read()
words = [' '.join('0x%02x' % b for b in data[i:i + 4])
         for i in range(0, len(data) - 3, 4)]
out = subprocess.run(['llvm-mc', '--disassemble', '--triple=aarch64'],
                     input='\n'.join(words) + '\n',
                     capture_output=True, text=True)
insts = [l.strip() for l in out.stdout.splitlines()
         if l.strip() and not l.strip().startswith('.text')]
for i, line in enumerate(insts):
    print('%#x:\t%s' % (start + 4 * i, line))
PY
