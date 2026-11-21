#!/bin/bash
# Capture the daemon's reply to kCBMsgIdDeviceGetNameMsg with a fresh client:
# rebuild and deploy the shim, restart bluetoothd, restart SpringBoard (a fresh
# Settings client with fresh device handles), open Settings > Bluetooth and
# print the name replies the shim copied into the append-only power log.
#
# Usage: bt-name-reply.sh [WAIT]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
LOG=/private/var/mobile/Library/Preferences/mondrian-bt-power.log
WAIT=${1:-25}

bash tools/wsl/attach.sh || exit 1
bash tools/build-mondrian-bt.sh out/gpu/mondrian-bt.dylib \
    > /tmp/bt-name-reply-build.log 2>&1 || {
	tail -5 /tmp/bt-name-reply-build.log
	exit 1
}
$RING wfile /private/var/vm/mondrian-bt.dylib out/gpu/mondrian-bt.dylib \
    >/dev/null || exit 1

$RING dump /tmp/bt-name-reply-before.txt >/dev/null
old=$(grep -a 'connected unit 1 from bluetoothd' /tmp/bt-name-reply-before.txt |
	sed -n 's/.*pid \([0-9]*\).*/\1/p' | tail -1)
echo "== restart bluetoothd (pid ${old:-none})"
if [ -n "${old:-}" ]; then
	$RING kill "$old" >/dev/null
	$RING wait 10 >/dev/null
fi

$RING dump /tmp/bt-name-reply-ui.txt >/dev/null
sb=$(grep -a 'SMP t=' /tmp/bt-name-reply-ui.txt | tail -1 |
	sed -n 's/.*SpringBoard(\([0-9]*\)).*/\1/p')
echo "== restart SpringBoard (pid ${sb:-none})"
if [ -n "${sb:-}" ]; then
	$RING kill "$sb" >/dev/null
	$RING wait 20 >/dev/null
fi

$RING swipe 720 2800 720 1000 250 >/dev/null
$RING wait 3 >/dev/null
$RING tap 205 780 >/dev/null
$RING wait 5 >/dev/null
$RING tap 720 1112 >/dev/null
$RING wait "$WAIT" >/dev/null
$RING screen out/bt-name-reply.png >/dev/null

: > out/bt-name-reply.log
off=0
while [ "$off" -lt 120000 ]; do
	$RING rf "$LOG" "$off" 1000 > /tmp/bt-name-reply-chunk.bin
	if head -c 2 /tmp/bt-name-reply-chunk.bin | grep -q '^rf'; then
		break
	fi
	n=$(wc -c < /tmp/bt-name-reply-chunk.bin)
	cat /tmp/bt-name-reply-chunk.bin >> out/bt-name-reply.log
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== $(wc -c < out/bt-name-reply.log) bytes"
grep -a 'xpc.name\|getName' out/bt-name-reply.log | tail -20
echo "== pane: out/bt-name-reply.png"
