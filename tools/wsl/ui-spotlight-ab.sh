#!/bin/bash
# Does the picture bridge keep Spotlight from running? 0402 skips the injection
# when the dylib is not in /private/var/vm, so removing it for one run is the
# A/B: Spotlight execs and dies (status 0x9) with it, and the Today view is left
# with a blurred backdrop.
#
# Usage: ui-spotlight-ab.sh [with|without]
#   without  delete the dylib, restart Spotlight, read the ring and the view
#   with     push the dylib back (the resting state)
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
MODE=${1:?usage: ui-spotlight-ab.sh with|without}

bash tools/wsl/attach.sh || exit 1
if [ "$MODE" = without ]; then
	$RING del /private/var/vm/mondrian-layer-bridge.dylib
	$RING wfile /private/var/vm/mondrian-layer-bridge-off.txt out/deep-app-ask.txt >/dev/null 2>&1
else
	$RING wfile /private/var/vm/mondrian-layer-bridge.dylib \
		out/gpu/mondrian-layer-bridge.dylib || exit 1
fi

printf 'kill Spotlight\n' > out/spot-kill.txt
$RING wfile /private/var/vm/bt-poke out/spot-kill.txt >/dev/null || exit 1
$RING wait 6
$RING key 3 down >/dev/null; $RING key 3 up >/dev/null
$RING wait 2
$RING swipe 720 400 720 1500 260 >/dev/null
$RING wait 10
$RING screen "out/spot-ab-$MODE.png"
$RING dump "out/spot-ab-$MODE.txt" >/dev/null 2>&1
echo "== exec/exit"
grep -a 'exec Spotlight\|exit Spotlight' "out/spot-ab-$MODE.txt" | tail -6
echo "capture out/spot-ab-$MODE.png"
