#!/bin/bash
# Deploy the shim that keeps the last HCI packets of a run and reads the exit
# report: `_exit` status, the reason in x19 and the packets that preceded it.
# The daemon restarts every ~16 s and every exec reloads the dylib, so no boot
# is needed after a shim change.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
LOG=/private/var/mobile/Library/Preferences/mondrian-bt-exit.log

if [ "${SKIP_BUILD:-0}" != 1 ]; then
	bash tools/build-mondrian-bt.sh out/gpu/mondrian-bt.dylib \
	    > /tmp/bt-shim-build.log 2>&1 || {
		tail -5 /tmp/bt-shim-build.log
		exit 1
	}
	tail -1 /tmp/bt-shim-build.log
fi

bash tools/wsl/attach.sh || exit 1
$RING wfile /private/var/vm/mondrian-bt.dylib out/gpu/mondrian-bt.dylib \
    || exit 1
echo "== waiting for a run to end"
$RING wait 45

: > /tmp/bt-exit.txt
off=0
while [ "$off" -lt 8000 ]; do
	$RING rf "$LOG" "$off" 1000 > /tmp/bt-exit-chunk.txt
	if head -c 2 /tmp/bt-exit-chunk.txt | grep -q '^rf'; then
		[ "$off" = 0 ] && echo "missing $LOG"
		break
	fi
	n=$(wc -c < /tmp/bt-exit-chunk.txt)
	cat /tmp/bt-exit-chunk.txt >> /tmp/bt-exit.txt
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== exit report ($(wc -c < /tmp/bt-exit.txt) bytes)"
grep -a -v 'frame ' /tmp/bt-exit.txt
