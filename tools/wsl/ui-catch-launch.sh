#!/bin/bash
# Tap an icon and capture the panel in a burst, to catch a screen that only
# exists for a second. On this port an app can build its whole view tree, get
# composited, and be killed again in about two seconds, so a capture taken after
# a wait shows the home screen and hides the app's own drawing.
#
# Usage: ui-catch-launch.sh X Y [FRAMES]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
X=${1:?usage: ui-catch-launch.sh X Y [FRAMES]}
Y=${2:?}
FRAMES=${3:-4}

bash tools/wsl/attach.sh || exit 1
$RING tap 360 1000 >/dev/null        # wake only; the next tap is the icon
$RING wait 1 >/dev/null
$RING tap "$X" "$Y" >/dev/null
for i in $(seq 1 "$FRAMES"); do
	$RING screen "out/catch-$i.png" >/dev/null 2>&1
done
ls -l out/catch-*.png | tail -"$FRAMES"
