#!/bin/bash
# Deploy the shim and make bluetoothd load it now: kill the daemon, let launchd
# start it again, then print the startup lines the new copy wrote to the
# append-only power log (the main log is not writable on this unit, and the
# kernel ring only carries the control channel's own messages).
#
# Usage: bt-restart-daemon.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
LOG=/private/var/mobile/Library/Preferences/mondrian-bt-power.log

bash tools/wsl/attach.sh || exit 1
bash tools/build-mondrian-bt.sh out/gpu/mondrian-bt.dylib > /tmp/bt-restart-build.log 2>&1 || {
	tail -5 /tmp/bt-restart-build.log
	exit 1
}
$RING wfile /private/var/vm/mondrian-bt.dylib out/gpu/mondrian-bt.dylib || exit 1

$RING dump /tmp/bt-restart-before.txt >/dev/null
old=$(grep -a 'BTCTL: connected' /tmp/bt-restart-before.txt |
	sed -n 's/.*from bluetoothd pid \([0-9]*\).*/\1/p' | tail -1)
echo "== old pid ${old:-none}"
if [ -n "${old:-}" ]; then
	$RING kill "$old"
	$RING wait 10
fi
$RING dump /tmp/bt-restart-after.txt >/dev/null
echo "== new connection: $(grep -a 'BTCTL: connected' /tmp/bt-restart-after.txt | tail -1)"

: > /tmp/bt-restart-log.txt
off=0
while [ "$off" -lt 40000 ]; do
	$RING rf "$LOG" "$off" 1000 > /tmp/bt-restart-chunk.txt
	if head -c 2 /tmp/bt-restart-chunk.txt | grep -q '^rf'; then
		break
	fi
	n=$(wc -c < /tmp/bt-restart-chunk.txt)
	cat /tmp/bt-restart-chunk.txt >> /tmp/bt-restart-log.txt
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== newest startup lines"
grep -a 'h4:' /tmp/bt-restart-log.txt | tail -3
