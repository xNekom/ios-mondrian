#!/bin/bash
# Wake and unlock. One press of the power button is a toggle, so pressing it
# once on a screen that is already on puts the phone to sleep and the swipe
# afterwards does nothing -- which reads as a wedged lock screen. Two presses a
# second apart always end on, then one long swipe from the bottom unlocks.
#
# Usage: ui-unlock.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING bl 1024 >/dev/null
$RING key 0 down >/dev/null; $RING key 0 up >/dev/null
$RING wait 1
$RING key 0 down >/dev/null; $RING key 0 up >/dev/null
$RING wait 2
$RING swipe 720 3120 720 700 500 >/dev/null
$RING wait 4
$RING screen out/unlock.png
