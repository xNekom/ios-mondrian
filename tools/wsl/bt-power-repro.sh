#!/bin/bash
# Reproduce the switch crash with the shim's power log in place and print the
# messages of the process that died. The dylib is deployed first; the drag that
# follows kills the process still running the old copy, so the *next* one loads
# the new shim, and the second drag kills that one with its log complete.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
LOG=/private/var/mobile/Library/Preferences/mondrian-bt-power.log

bash tools/wsl/attach.sh || exit 1
bash tools/build-mondrian-bt.sh out/gpu/mondrian-bt.dylib > /tmp/bt-power-build.log 2>&1 || {
	tail -5 /tmp/bt-power-build.log
	exit 1
}
$RING wfile /private/var/vm/mondrian-bt.dylib out/gpu/mondrian-bt.dylib || exit 1

echo "== first drag (retires the old copy)"
$RING swipe 1330 478 1200 478 150
$RING wait 30

echo "== second drag (kills the daemon that loaded the new shim)"
$RING swipe 1330 478 1200 478 150
$RING wait 5
$RING dump out/bt-power-repro.txt >/dev/null

pid=$(grep -a 'exit bluetoothd\[' out/bt-power-repro.txt | tail -1 |
	sed -n 's/.*exit bluetoothd\[\([0-9]*\)\].*/\1/p')
echo "== dead pid: ${pid:-?}"

: > /tmp/bt-power.txt
off=0
while [ "$off" -lt 60000 ]; do
	$RING rf "$LOG" "$off" 1000 > /tmp/bt-power-chunk.txt
	if head -c 2 /tmp/bt-power-chunk.txt | grep -q '^rf'; then
		break
	fi
	n=$(wc -c < /tmp/bt-power-chunk.txt)
	cat /tmp/bt-power-chunk.txt >> /tmp/bt-power.txt
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
cp /tmp/bt-power.txt out/bt-power.log
echo "== last 30 lines for pid ${pid:-?}"
grep -a "mondrian-bt\[$pid\]" /tmp/bt-power.txt | tail -30
