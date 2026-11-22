#!/bin/bash
# Tap an app icon and report what the kernel says about its process: does it
# exec, and does it exit at once with status 0x9 (SIGKILL)?
#
# Usage: ui-launch-app.sh X Y [NAME]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
X=${1:?usage: ui-launch-app.sh X Y [NAME]}
Y=${2:?usage: ui-launch-app.sh X Y [NAME]}
NAME=${3:-Preferences}

bash tools/wsl/attach.sh || exit 1
$RING bl 1024 >/dev/null
$RING key 3 down >/dev/null; $RING key 3 up >/dev/null
$RING wait 2
$RING tap "$X" "$Y" >/dev/null
$RING wait 6
$RING dump out/launch-app.txt >/dev/null 2>&1
echo "== exec/exit $NAME"
grep -a "exec $NAME\|exit $NAME\|CRASH $NAME" out/launch-app.txt | tail -6
