#!/bin/bash
# Arm the app bridge's view dump and pull one process's result.
#
# The dump is written to /private/var/mobile/Library/Preferences/
# mondrian-appdeep-<pid>.log, one file per process, because two processes can
# dump in the same second. The process must already run the pushed bridge:
# reload it with tools/wsl/ui-kill-by-name.sh APP, then reopen the screen.
#
# Usage: ui-deep-app-pull.sh PID [NUMBER]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
PID=${1:?usage: ui-deep-app-pull.sh PID [NUMBER]}
N=${2:-1}
LOG=/private/var/mobile/Library/Preferences/mondrian-appdeep-${PID}.log

bash tools/wsl/attach.sh || exit 1
$RING wfile /private/var/vm/mondrian-layer-bridge.dylib \
	out/gpu/mondrian-layer-bridge.dylib >/dev/null || exit 1
printf '%s\n' "$N" > out/deep-app-ask.txt
$RING wfile /private/var/vm/mondrian-deep-app out/deep-app-ask.txt >/dev/null || exit 1
$RING wait 5

: > out/appdeep.log
off=0
for _ in $(seq 1 60); do
	$RING rf "$LOG" "$off" 1000 > /tmp/deep-chunk.bin 2>/dev/null
	if head -c 2 /tmp/deep-chunk.bin | grep -q '^rf'; then
		break
	fi
	n=$(wc -c < /tmp/deep-chunk.bin)
	cat /tmp/deep-chunk.bin >> out/appdeep.log
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== $(wc -c < out/appdeep.log) bytes in out/appdeep.log"
head -40 out/appdeep.log
