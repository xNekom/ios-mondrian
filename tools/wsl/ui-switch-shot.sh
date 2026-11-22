#!/bin/bash
# Open Settings and blow up the Airplane Mode switch, so "the knob is not
# drawn" is read from a picture instead of inferred from the ring. The ring's
# capture is half the panel, so the switch at panel 1240,848 is at 620,424.
#
# Usage: ui-switch-shot.sh [OUT.png] [CROP.png]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
OUT=${1:-out/switch.png}
CROP=${2:-out/switch-crop.png}

bash tools/wsl/attach.sh || exit 1
$RING tap 360 1000 >/dev/null
$RING wait 20 >/dev/null
$RING tap 202 756 >/dev/null
$RING wait 6 >/dev/null
$RING screen "$OUT" >/dev/null
python3 tools/png-crop.py "$OUT" "$CROP" 560 390 140 70 6
$RING dump out/switch-ring.txt >/dev/null 2>&1
echo "== exec/exit"
grep -a 'exec Preferences\|exit Preferences' out/switch-ring.txt | tail -3
