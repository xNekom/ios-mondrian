#!/bin/bash
# Does the H4 notify no-op stop the Settings switch from killing bluetoothd?
# Deploys the shim, restarts the daemon so it loads the new copy, then drags
# the Bluetooth switch off and on again. The old failure was reproducible on
# every drag: `exit bluetoothd` with `sig 11 pc 0x0 far 0x0 lr
# bluetoothd + 0xf3b50`. With the no-op the drag must leave the pid alone.
#
# Usage: verify-bt-switch.sh [ICON_X ICON_Y ROW_X ROW_Y]
# Coordinates default to the Settings icon, the Bluetooth row and the switch
# centre of the 1440x3200 panel (captures are half scale).
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
SHIM=/private/var/mobile/Library/Preferences/mondrian-bt.log
ICON_X=${1:-205}
ICON_Y=${2:-780}
ROW_X=${3:-720}
ROW_Y=${4:-1112}
KNOB_ON_X=1330
KNOB_OFF_X=1200
SW_Y=478

pull() {
	local src=$1 dst=$2 off=0
	: > "$dst"
	while [ "$off" -lt 200000 ]; do
		$RING rf "$src" "$off" 1000 > /tmp/bt-pull.bin
		if head -c 2 /tmp/bt-pull.bin | grep -q '^rf'; then
			return 1
		fi
		n=$(wc -c < /tmp/bt-pull.bin)
		cat /tmp/bt-pull.bin >> "$dst"
		[ "$n" -lt 1000 ] && break
		off=$((off + n))
	done
	return 0
}

bash tools/wsl/attach.sh || exit 1
bash tools/build-mondrian-bt.sh out/gpu/mondrian-bt.dylib > /tmp/bt-switch-build.log 2>&1 || {
	tail -5 /tmp/bt-switch-build.log
	exit 1
}
$RING wfile /private/var/vm/mondrian-bt.dylib out/gpu/mondrian-bt.dylib || exit 1

$RING dump /tmp/bt-before.txt >/dev/null
old=$(grep -a 'BTCTL: connected' /tmp/bt-before.txt |
	sed -n 's/.*from bluetoothd pid \([0-9]*\).*/\1/p' | tail -1)
echo "== restart bluetoothd (pid ${old:-none}) with the new shim"
if [ -n "${old:-}" ]; then
	$RING kill "$old"
	$RING wait 8
fi

echo "== open Settings > Bluetooth"
$RING tap "$ICON_X" "$ICON_Y"
$RING wait 10
$RING screen out/bt-settings-root.png
$RING tap "$ROW_X" "$ROW_Y"
$RING wait 12
$RING screen out/bt-switch-before.png

pull "$SHIM" out/bt-switch-shim.log
grep -a 'h4:' out/bt-switch-shim.log | tail -2

echo "== drag off"
$RING swipe "$KNOB_ON_X" "$SW_Y" "$KNOB_OFF_X" "$SW_Y" 150
$RING wait 6
$RING screen out/bt-switch-off.png
$RING wait 4
$RING dump out/bt-switch-off.txt >/dev/null
echo "-- exits after off: $(grep -a -c 'exit bluetoothd' out/bt-switch-off.txt)"
grep -a 'exit bluetoothd' out/bt-switch-off.txt | tail -2
echo "-- last connection: $(grep -a 'BTCTL: connected' out/bt-switch-off.txt | tail -1)"

echo "== drag on"
$RING swipe "$KNOB_OFF_X" "$SW_Y" "$KNOB_ON_X" "$SW_Y" 150
$RING wait 8
$RING screen out/bt-switch-on.png
$RING dump out/bt-switch-on.txt >/dev/null
echo "-- exits after on: $(grep -a -c 'exit bluetoothd' out/bt-switch-on.txt)"
echo "-- last connection: $(grep -a 'BTCTL: connected' out/bt-switch-on.txt | tail -1)"

pull "$SHIM" out/bt-switch-shim.log
echo "== shim tail"
grep -a 'h4:\|power' out/bt-switch-shim.log | tail -12
echo "== panels: out/bt-switch-before.png out/bt-switch-off.png out/bt-switch-on.png"
