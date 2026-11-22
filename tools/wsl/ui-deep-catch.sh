#!/bin/bash
# Arm the bridge's view dump, launch the app, and pull what it wrote before the
# app died. An app on this port can be killed about two seconds after `exec`
# (measured 2026-11-22), so the dump timer runs at half a second and this script
# arms the marker before the tap instead of after.
#
# Usage: ui-deep-catch.sh X Y NAME [ARM]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
X=${1:?usage: ui-deep-catch.sh X Y NAME [ARM]}
Y=${2:?}
NAME=${3:?}
ARM=${4:-21}

bash tools/wsl/attach.sh || exit 1
$RING wfile /private/var/vm/mondrian-layer-bridge.dylib \
	out/gpu/mondrian-layer-bridge.dylib >/dev/null || exit 1
printf '%s\n' "$ARM" > out/deep-arm.txt
$RING wfile /private/var/vm/mondrian-deep-app out/deep-arm.txt >/dev/null || exit 1

$RING tap 360 1000 >/dev/null
$RING wait 20 >/dev/null
$RING tap "$X" "$Y" >/dev/null
$RING wait 4 >/dev/null

bash tools/wsl/ui-bridge-alive.sh 6 >/dev/null 2>&1
pid=$(grep -a "^$NAME pid" out/bridge-alive.log | tail -1 |
	sed -n "s/^$NAME pid \\([0-9][0-9]*\\): loaded/\\1/p")
echo "== $NAME pid ${pid:-none}"
if [ -z "${pid:-}" ]; then
	$RING dump out/deep-catch-ring.txt >/dev/null 2>&1
	tail -4 out/deep-catch-ring.txt
	exit 1
fi

LOG="/private/var/mobile/Library/Preferences/mondrian-appdeep-$pid.log"
: > out/appdeep.log
off=0
for _ in $(seq 1 80); do
	$RING rf "$LOG" "$off" 1000 > /tmp/deep-chunk.bin 2>/dev/null
	if head -c 2 /tmp/deep-chunk.bin | grep -q '^rf'; then
		break
	fi
	n=$(wc -c < /tmp/deep-chunk.bin)
	cat /tmp/deep-chunk.bin >> out/appdeep.log
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== $(wc -c < out/appdeep.log) bytes"
grep -a 'MONDRIAN APPDEEP' out/appdeep.log | head -60
