#!/bin/bash
# Ask the controller whether it will scan with the extended commands. Deploys
# the shim, drops /private/var/vm/bt-ext-probe, clears the power log and
# restarts bluetoothd: qca_boot then sends 0x2041/0x2042 and writes the statuses
# and the first event to the append-only log.
#
# Usage: bt-ext-probe.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
LOG=/private/var/mobile/Library/Preferences/mondrian-bt-power.log

bash tools/wsl/attach.sh || exit 1
bash tools/build-mondrian-bt.sh out/gpu/mondrian-bt.dylib > /tmp/bt-ext-build.log 2>&1 || {
	tail -5 /tmp/bt-ext-build.log
	exit 1
}
$RING wfile /private/var/vm/mondrian-bt.dylib out/gpu/mondrian-bt.dylib || exit 1
printf '1' > /tmp/bt-ext-marker
$RING wfile /private/var/vm/bt-ext-probe /tmp/bt-ext-marker || exit 1
$RING del "$LOG" >/dev/null 2>&1

$RING dump /tmp/bt-ext-before.txt >/dev/null
pid=$(grep -a 'BTCTL: connected' /tmp/bt-ext-before.txt |
	sed -n 's/.*pid \([0-9]*\).*/\1/p' | tail -1)
echo "== restart bluetoothd (pid ${pid:-none})"
if [ -n "${pid:-}" ]; then
	$RING kill "$pid"
	$RING wait 12
fi

: > out/bt-ext.log
off=0
while [ "$off" -lt 60000 ]; do
	$RING rf "$LOG" "$off" 1000 > /tmp/bt-ext-chunk.bin
	if head -c 2 /tmp/bt-ext-chunk.bin | grep -q '^rf'; then
		break
	fi
	n=$(wc -c < /tmp/bt-ext-chunk.bin)
	cat /tmp/bt-ext-chunk.bin >> out/bt-ext.log
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== $(wc -c < out/bt-ext.log) bytes"
grep -a 'ext:' out/bt-ext.log | tail -8
$RING del /private/var/vm/bt-ext-probe >/dev/null 2>&1
