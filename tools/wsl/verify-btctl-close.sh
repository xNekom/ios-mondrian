#!/bin/bash
# Read what the instrumented HCI control says about each Bluetooth connection:
# which process opened it, packets written, failed writes, packets read,
# connection age and idle time before it closed. A close after `fail 0` with a
# large idle is the daemon's session handling; a close right after a
# `write failed` line is the transport.
#
# Run after a boot with the instrumented kernel. The Settings taps are a best
# effort: the home screen needs about twenty seconds after the ring answers,
# and the transport cycles whether or not the pane is up (measured 2026-11-21).
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING bl 1024
$RING wait 20

echo "== open Settings > Bluetooth"
$RING tap 205 780
$RING wait 8
$RING tap 720 1112
$RING wait 8
$RING screen out/btctl-pane.png || exit 1

echo "== let three transport cycles run"
$RING wait 50
$RING screen out/btctl-pane-late.png || exit 1
$RING dump out/btctl-close.txt || exit 1

echo "== connects (process matters)"
grep -a 'BTCTL: connected' out/btctl-close.txt | tail -10
echo "== connection summaries"
grep -a 'BTCTL: disconnected' out/btctl-close.txt | tail -10
echo "== failed writes"
grep -a 'BTCTL: write failed' out/btctl-close.txt | tail -6
echo "== panels are out/btctl-pane.png and out/btctl-pane-late.png"
