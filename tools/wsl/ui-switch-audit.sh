#!/bin/bash
# Does a switch inside an app draw in both states? The Settings panes are the
# place the knob was reported missing; the Wi-Fi pane is safe to toggle (the
# USB console is not Wi-Fi) and its switch sits alone at the top.
#
# Usage: ui-switch-audit.sh X Y
# X Y is the switch centre in panel pixels, taken from a capture of the pane.
# A 150 ms drag inside the control is the gesture that changes a UISwitch
# (docs/UI_PERFORMANCE.md); a 0 ms tap does not.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
X=${1:?usage: ui-switch-audit.sh X Y}
Y=${2:?usage: ui-switch-audit.sh X Y}

bash tools/wsl/attach.sh || exit 1
$RING bl 1024

$RING screen out/switch-app-before.png
$RING swipe "$X" "$Y" "$((X + 60))" "$Y" 150
$RING wait 2
$RING screen out/switch-app-after.png
echo "== drag the other way"
$RING swipe "$((X + 60))" "$Y" "$X" "$Y" 150
$RING wait 2
$RING screen out/switch-app-back.png
echo "captures: out/switch-app-before.png, out/switch-app-after.png, out/switch-app-back.png"
