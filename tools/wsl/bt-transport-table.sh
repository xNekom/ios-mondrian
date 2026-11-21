#!/bin/bash
# Dump the static HCI transport tables in bluetoothd: each one is a struct of
# function pointers, and the crash is a tail call through the slot at +0x60 of
# whichever table BT_HCI_TRANSPORT selected. Comparing the slot across the
# tables shows whether H4 is the only one with a hole there.
#
# Usage: bt-transport-table.sh [BINARY]
set -u
BIN=${1:-/root/btbin/iOSRoot/usr/sbin/bluetoothd}

echo "== H4 0x100844228"
xxd -g8 -s $((0x844228)) -l 128 "$BIN"
echo "== H4DS 0x100844350"
xxd -g8 -s $((0x844350)) -l 128 "$BIN"
echo "== H4BC 0x1008442b8"
xxd -g8 -s $((0x8442b8)) -l 128 "$BIN"
echo "== H5 0x1008443e0"
xxd -g8 -s $((0x8443e0)) -l 128 "$BIN"
echo "== APPLEBT 0x1008440b0"
xxd -g8 -s $((0x8440b0)) -l 128 "$BIN"
