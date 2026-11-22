#!/bin/bash
# Open Settings and prove it stayed up.
#
# Two measured traps are handled here: the power key is a toggle (a second press
# locks the screen), and `mondrianfb_blank=30` turns the panel off after 30 s of
# no frame, so the touch that wakes it is eaten and pays a DCS panel-on that
# stalls the compositor for about 17 s. The first tap is therefore only a wake,
# and the launch tap comes after the stall.
#
# Usage: ui-settings-open.sh [OUT.png]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
OUT=${1:-out/settings-open.png}

bash tools/wsl/attach.sh || exit 1
$RING tap 360 1000 >/dev/null
$RING wait 20 >/dev/null
$RING tap 202 756 >/dev/null
$RING wait 12 >/dev/null
$RING screen "$OUT"
$RING dump out/settings-open.txt >/dev/null 2>&1
echo "== exec/exit"
grep -a 'exec Preferences\|exit Preferences' out/settings-open.txt | tail -4
echo "== rate"
grep -a 'mondrian-gl: rate' out/settings-open.txt | tail -3
