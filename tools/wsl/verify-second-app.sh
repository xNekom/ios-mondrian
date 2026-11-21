#!/bin/bash
# Open one app from the home screen and check that 0402 injected the layer
# bridge into it: a load line for that process, the surfaces it hands to
# QuartzCore, and no zero-format copy from the server. This is the check that
# the bridge is not a Settings-only path.
#
# Usage: tools/wsl/verify-second-app.sh NAME X Y
# The coordinate comes from a panel capture of this same boot (1440x3200);
# nothing here is guessed.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
NAME=${1:?usage: verify-second-app.sh NAME X Y}
X=${2:?usage: verify-second-app.sh NAME X Y}
Y=${3:?usage: verify-second-app.sh NAME X Y}
PNG="out/second-app-$NAME.png"
TXT="out/second-app-$NAME.txt"

bash tools/wsl/attach.sh || exit 1
$RING bl 1024
$RING tap "$X" "$Y"
$RING wait 8

$RING screen "$PNG" || exit 1
$RING dump "$TXT" || exit 1

echo "== bridge load"
grep -a "loaded in $NAME" "$TXT" | tail -2
echo "== contents callers"
grep -a 'contents .* for \|handed to QuartzCore' "$TXT" | tail -8
echo "== server zero copy"
grep -a 'backboardd create.*fmt 0x0' "$TXT" | tail -2
echo "== present"
grep -a 'MONDRIAN FB: present' "$TXT" | tail -2
echo "== crash"
grep -a 'CRASH SpringBoard' "$TXT" | tail -2
echo "== panel and ring are in $PNG and $TXT"
