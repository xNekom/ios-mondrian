#!/bin/bash
# Is an HCI opcode compiled into bluetoothd? Disassembles the local copy (byte
# identical to the device's, see bt-local-binary.sh) and reports where an
# immediate with that value is loaded. That answers "does the daemon have this
# command at all" without guessing from a packet that the log may have cut.
#
# Usage: bt-find-immediate.sh VALUE [BINARY]      (VALUE in hex, e.g. 0x419)
set -u
BIN=${2:-/root/btbin/iOSRoot/usr/sbin/bluetoothd}
VALUE=${1:?usage: bt-find-immediate.sh VALUE [BINARY]}

if [ ! -s /tmp/bt.dis ]; then
	llvm-objdump --macho -d "$BIN" > /tmp/bt.dis 2>/dev/null || exit 1
fi
grep -n "#$VALUE" /tmp/bt.dis | head -12
