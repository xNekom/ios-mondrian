#!/bin/bash
# Open Settings > Bluetooth and collect everything one boot needs to answer
# "does the pane draw a name": the screenshot, the ring's scan counters and
# injected names, the daemon's name replies (kCBMsgArgName) and the decoded
# LE/classic names.
#
# The pane is opened through LaunchServices (bt-pane-open.sh), not by tapping
# the Settings icon: the icon's position moves between boots and a tap on the
# wrong pixel is indistinguishable from a pane that never opened.
#
# Usage: bt-name-check.sh [WAIT]
#   WAIT      seconds to let the pane scan (default 30)
#   BT_ROW=1  also tap the Bluetooth row at 720,1118 after opening (use when
#             the URL lands on Settings' root instead of the pane)
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
WAIT=${1:-30}

bash tools/wsl/attach.sh || exit 1
$RING bl 1024 >/dev/null 2>&1
$RING swipe 720 2800 720 1000 250 >/dev/null
$RING wait 4 >/dev/null
bash tools/wsl/bt-pane-open.sh 10 >/dev/null 2>&1
$RING screen out/bt-name-settings.png >/dev/null
if [ "${BT_ROW:-0}" = 1 ]; then
	$RING tap 720 1118 >/dev/null
	$RING wait 4 >/dev/null
fi
$RING wait "$WAIT" >/dev/null
$RING screen out/bt-name-check.png >/dev/null
$RING dump out/bt-name-check.txt >/dev/null

echo "== scan summary"
grep -a 'BTCTL: scan le meta' out/bt-name-check.txt | tail -2
echo "== injected and requested names"
grep -a 'BTCTL: ext name\|name request ' out/bt-name-check.txt | tail -6
echo "== decoded names"
bash tools/wsl/bt-le-names.sh out/bt-name-check.txt | tail -14

bash tools/wsl/bt-power-log.sh >/dev/null 2>&1
echo "== daemon name replies"
grep -a 'kCBMsgArgName' out/bt-power.log | tail -8
echo "== pane: out/bt-name-check.png"
