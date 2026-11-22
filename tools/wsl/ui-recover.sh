#!/bin/bash
# Recover the shell after an experiment wedged a view: respring, wake, unlock,
# then leave the phone on the home screen with a capture.
#
# Usage: ui-recover.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING respring || exit 1
$RING wait 25
$RING bl 1024 >/dev/null
$RING key 0 down >/dev/null; $RING key 0 up >/dev/null
$RING wait 3
$RING swipe 720 1500 720 600 260 >/dev/null
$RING wait 5
$RING screen out/recovered.png
