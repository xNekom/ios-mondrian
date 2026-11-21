#!/bin/bash
# Does the Bluetooth switch gesture reach UIControl's action dispatch? Push the
# bridge with the switch probe, arm it, relaunch Preferences, drag both switches
# (Bluetooth and the Control Center one that is known to work) and read the
# action lines each one produces.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING bl 1024

echo "== deploy the bridge with the probe and arm it"
$RING wfile /private/var/vm/mondrian-layer-bridge.dylib \
	out/gpu/mondrian-layer-bridge.dylib || exit 1
printf '1\n' > /tmp/bridge-switch-probe
$RING wfile /private/var/vm/bridge-switch-probe /tmp/bridge-switch-probe || exit 1

echo "== relaunch Preferences"
$RING dump /tmp/pref-before.txt
pid=$(grep -a 'loaded in Preferences' /tmp/pref-before.txt |
	sed -n 's/.*MONDRIAN BRIDGE\[\([0-9][0-9]*\)\]: loaded in Preferences.*/\1/p' |
	tail -1)
if [ -n "$pid" ]; then
	echo "kill Preferences $pid"
	$RING kill "$pid"
	$RING wait 2
fi
$RING tap 200 810
$RING wait 6
$RING tap 720 1112
$RING wait 4
$RING screen out/probe-bt-pane.png || exit 1

echo "== drag the Bluetooth switch off"
$RING swipe 1330 476 1200 476 150
$RING wait 4
$RING screen out/probe-bt-after.png || exit 1
$RING dump /tmp/probe-bt.txt

echo "-- switch actions after the Bluetooth drag"
awk '/MONDR USB: touch 1330,476/ { start = NR }
     { line[NR] = $0 }
     END { for (i = start; i <= NR; i++) print line[i] }' /tmp/probe-bt.txt |
	grep -a 'switch action\|loaded in Preferences' | tail -6

echo "== the Control Center switch, known to toggle"
$RING tap 80 244
$RING wait 3
$RING tap 720 2078
$RING wait 4
$RING screen out/probe-cc-pane.png || exit 1
$RING swipe 1330 626 1200 626 150
$RING wait 4
$RING dump /tmp/probe-cc.txt

echo "-- switch actions after the Control Center drag"
awk '/MONDR USB: touch 1330,626/ { start = NR }
     { line[NR] = $0 }
     END { for (i = start; i <= NR; i++) print line[i] }' /tmp/probe-cc.txt |
	grep -a 'switch action' | tail -6

echo "== disarm"
$RING del /private/var/vm/bridge-switch-probe >/dev/null 2>&1 || true
echo "== panels are out/probe-bt-pane.png, out/probe-bt-after.png, out/probe-cc-pane.png"
