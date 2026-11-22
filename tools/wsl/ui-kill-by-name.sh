#!/bin/bash
# Kill a process by name from inside the phone, so a rebuilt dylib can be loaded
# into a service that survives a respring (Spotlight is one). The Bluetooth
# shim runs as root and reads /private/var/vm/bt-poke every 500 ms; `kill NAME`
# is the command this adds.
#
# Usage: ui-kill-by-name.sh NAME
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
NAME=${1:?usage: ui-kill-by-name.sh NAME}
MARKER=out/bt-poke.txt

bash tools/wsl/attach.sh || exit 1
$RING wfile /private/var/vm/mondrian-bt.dylib out/gpu/mondrian-bt.dylib >/dev/null 2>&1 ||
	{ echo "wfile mondrian-bt failed" >&2; exit 1; }

# The shim is only in new daemon instances: restart bluetoothd once.
$RING dump /tmp/kill-before.txt >/dev/null 2>&1
bpid=$(grep -a 'BTCTL: connected .* from bluetoothd pid' /tmp/kill-before.txt |
	sed -n 's/.*from bluetoothd pid \([0-9][0-9]*\).*/\1/p' | tail -1)
if [ -n "${bpid:-}" ]; then
	$RING kill "$bpid" >/dev/null
	$RING wait 6
fi

printf 'kill %s\n' "$NAME" > "$MARKER"
$RING wfile /private/var/vm/bt-poke "$MARKER" >/dev/null || exit 1
$RING wait 3

# The shim only appends to its own log, so read it the windowed way.
bash tools/wsl/bt-read-log.sh \
	/private/var/mobile/Library/Preferences/mondrian-bt-power.log \
	out/bt-kill.log 0 >/dev/null 2>&1
grep -a 'poke: kill' out/bt-kill.log | tail -3
