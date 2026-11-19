#!/bin/bash
# One boot that answers whether bluetoothd uses /dev/cu.bluetooth.
#
#   tools/wsl/bt-tty.sh              # boot the kernel on disk and read the ring
#   ATTEMPTS=1 tools/wsl/bt-tty.sh   # a single RAM-boot attempt
#
# What to look for, in order: `MONDRIAN BTTTY: /dev/cu.bluetooth major N` from
# the root-mount hook (the node exists before launchd), then `MONDRIAN BTTTY:
# open pid N` from bluetoothd, the termios line, and the first `tx`/`rx`
# packets. A boot that shows the node but no open means bluetoothd chose
# another transport; a boot with no BTTTY line at all means the hook did not
# run or the driver did not register.
set -u
cd "$(dirname "$0")/../.." || exit 1
OUT=${OUT:-/root/cycle/ring-bttty.txt}

echo "== boot the kernel on disk"
timeout 1500 bash tools/wsl/cycle.sh --no-build > /root/cycle/bttty-boot.log 2>&1
BOOT=$?
tail -4 /root/cycle/bttty-boot.log
[ "$BOOT" = 0 ] || echo "cycle.sh exited $BOOT: the ring may be from another kernel"

bash tools/wsl/attach.sh > /dev/null 2>&1
timeout 250 python3 tools/usb-ring.py dump "$OUT" > /dev/null 2>&1

echo "== the node"
grep -a 'MONDRIAN BTTTY: /dev/cu.bluetooth' "$OUT" | tail -2
echo "== bluetoothd"
grep -a -e 'exec bluetoothd' -e 'exit bluetoothd' "$OUT" | tail -6
echo "== the port"
grep -a 'MONDRIAN BTTTY: open\|MONDRIAN BTTTY: termios\|MONDRIAN BTTTY: close' "$OUT" | tail -8
echo "== the packets"
grep -a -e 'MONDRIAN BTTTY: tx' -e 'MONDRIAN BTTTY: rx' -e 'MONDRIAN BTTTY: prepared' "$OUT" | tail -18
echo "== the ring is $OUT"
