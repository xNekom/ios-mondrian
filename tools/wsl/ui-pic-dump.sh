#!/bin/bash
# Pull the raw pictures the bridge handed to QuartzCore during one app launch.
#
# The app's own pictures are converted inside the app (and an app on this port
# can be killed about two seconds after `exec`), so the only way to see what a
# 129x129 knob really contains is the bytes the bridge wrote out. The ring names
# every picture the app created (`MONDRIAN SURF: <app> create ... WxH ... bpr`),
# and the dump's file name carries those three numbers, so the size list comes
# from the ring and the files are fetched by name.
#
# Usage: ui-pic-dump.sh X Y NAME
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
X=${1:?usage: ui-pic-dump.sh X Y NAME}
Y=${2:?}
NAME=${3:?}
DIR=/private/var/mobile/Library/Preferences

bash tools/wsl/attach.sh || exit 1
$RING wfile /private/var/vm/mondrian-layer-bridge.dylib \
	out/gpu/mondrian-layer-bridge.dylib >/dev/null || exit 1
printf '1\n' > out/pic-arm.txt
$RING wfile /private/var/vm/mondrian-dump-picture out/pic-arm.txt >/dev/null || exit 1

$RING tap 360 1000 >/dev/null
$RING wait 20 >/dev/null
$RING tap "$X" "$Y" >/dev/null
$RING wait 4 >/dev/null
$RING dump out/pic-ring.txt >/dev/null 2>&1

grep -a "MONDRIAN SURF: $NAME create" out/pic-ring.txt | tail -40 |
	sed -n 's/.* create id [0-9]* \([0-9]*\)x\([0-9]*\) .* bpr \([0-9]*\) .*/\1 \2 \3/p' |
	sort -u | while read -r w h bpr; do
	for n in 0 1 2 3 4 5 6 7; do
		LOG="$DIR/mondrian-pic-${w}x${h}-${bpr}-${n}.bgra"
		$RING rf "$LOG" 0 1000 > /tmp/pic-head.bin 2>/dev/null
		if head -c 2 /tmp/pic-head.bin | grep -q '^rf'; then
			break
		fi
		: > "out/pic-${w}x${h}-${bpr}-${n}.bgra"
		off=0
		while :; do
			$RING rf "$LOG" "$off" 1000 > /tmp/pic-chunk.bin 2>/dev/null
			if head -c 2 /tmp/pic-chunk.bin | grep -q '^rf'; then
				break
			fi
			cat /tmp/pic-chunk.bin >> "out/pic-${w}x${h}-${bpr}-${n}.bgra"
			[ "$(wc -c < /tmp/pic-chunk.bin)" -lt 1000 ] && break
			off=$((off + 1000))
		done
		echo "== ${w}x${h} stride ${bpr} #$n: $(wc -c < "out/pic-${w}x${h}-${bpr}-${n}.bgra") bytes"
	done
done
