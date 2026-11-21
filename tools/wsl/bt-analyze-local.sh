#!/bin/bash
# Look at the local copy of the phone's bluetoothd with the LLVM Mach-O tools:
# whether any names survive, the section layout, and the code around a crash
# offset. The file is byte-identical to the one on the device (see
# bt-local-binary.sh), so a local answer is the device's answer.
#
# Usage: bt-analyze-local.sh [BINARY]
set -u
BIN=${1:-/root/btbin/iOSRoot/usr/sbin/bluetoothd}

echo "== nm (names that survive)"
llvm-nm --numeric-sort "$BIN" 2>&1 | head -20
echo "== sections"
llvm-objdump --macho --section-headers "$BIN" 2>/dev/null | head -20
echo "== 0x1000f3b44"
llvm-objdump --macho -d --start-address=0x1000f3b44 --stop-address=0x1000f3b90 "$BIN" 2>/dev/null | tail -14
echo "== 0x1000e2aac"
llvm-objdump --macho -d --start-address=0x1000e2aac --stop-address=0x1000e2b90 "$BIN" 2>/dev/null | tail -40
