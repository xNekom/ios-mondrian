#!/bin/bash
# Does a Control Center capsule answer? Captures the sheet before and after one
# gesture on the brightness capsule; the fill's top edge is the reading.
#
# Usage: ui-cc-capsule.sh [MODE] [X Y]
# MODE is tap (0 ms) or drag (150 ms, the gesture a UIControl actually takes).
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
MODE=${1:-drag}
X=${2:-860}
Y=${3:-1000}

bash tools/wsl/attach.sh || exit 1
$RING bl 1024 >/dev/null
$RING key 3 down >/dev/null; $RING key 3 up >/dev/null
$RING wait 2
$RING swipe 1400 8 1400 1300 220 >/dev/null
$RING wait 4
$RING screen out/cc-capsule-before.png || exit 1
case "$MODE" in
tap) $RING tap "$X" "$Y" >/dev/null ;;
drag) $RING swipe "$X" "$((Y + 90))" "$X" "$Y" 150 >/dev/null ;;
*) echo "usage: ui-cc-capsule.sh [tap|drag] [X Y]" >&2; exit 2 ;;
esac
$RING wait 3
$RING screen out/cc-capsule-after.png
$RING tap 700 1900 >/dev/null
$RING wait 2
echo "captures: out/cc-capsule-before.png, out/cc-capsule-after.png ($MODE)"
