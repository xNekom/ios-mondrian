#!/bin/bash
# Does a UISwitch draw outside Settings? The bridge adds an off and an on switch
# to the first visible window of whichever app it is injected into, behind
# /private/var/vm/mondrian-switch-test. The app has to be restarted after the
# dylib is pushed, or the running process keeps the bridge it loaded at launch.
set -u
cd "$(dirname "$0")/../.." || exit 1
R="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$R wfile /private/var/vm/mondrian-layer-bridge.dylib \
	out/gpu/mondrian-layer-bridge.dylib || exit 1
printf '1\n' > /tmp/switch-test
$R wfile /private/var/vm/mondrian-switch-test /tmp/switch-test || exit 1

kill_app() {
	local name=$1 pid
	$R dump /tmp/switch-apps.txt >/dev/null 2>&1
	pid=$(grep -a -o "MONDRIAN BRIDGE\[[0-9]*\]: loaded in $name" \
		/tmp/switch-apps.txt | tail -1 | sed 's/.*\[\([0-9]*\)\].*/\1/')
	if [ -n "$pid" ]; then
		echo "kill $name $pid"
		$R kill "$pid" >/dev/null
		$R wait 2 >/dev/null
	fi
}

echo "== home, then a fresh Settings"
$R key 3 down >/dev/null; $R key 3 up >/dev/null
$R wait 2 >/dev/null
kill_app Preferences
$R tap 205 780 >/dev/null
$R wait 10 >/dev/null
$R screen out/switch-settings.png || exit 1
$R dump out/switch-settings.txt >/dev/null 2>&1
grep -a -o 'switch test added in [A-Za-z]*' out/switch-settings.txt | tail -2

echo "== home, then a fresh Messages"
$R key 3 down >/dev/null; $R key 3 up >/dev/null
$R wait 2 >/dev/null
kill_app MobileSMS
$R tap 1020 2980 >/dev/null
$R wait 10 >/dev/null
$R screen out/switch-messages.png || exit 1
$R dump out/switch-messages.txt >/dev/null 2>&1
grep -a -o 'switch test added in [A-Za-z]*' out/switch-messages.txt | tail -2

echo "== disarm and close both"
$R del /private/var/vm/mondrian-switch-test >/dev/null 2>&1 || true
kill_app Preferences
kill_app MobileSMS
echo "== panels: out/switch-settings.png out/switch-messages.png"
