#!/bin/bash
# Print the head of a crash report from the phone, in chunks. The ring only
# says `CRASH <name> ... sig 11 code ...`; the report carries the faulting
# thread and the frame that made the access, and that decides whether the fix
# is in a driver, a hook or the process itself.
#
# Usage: crash-log.sh PATH [BYTES]
# List the directory first (`usb-ring.py ls /private/var/mobile/Library/Logs/CrashReporter`)
# and pass one of its entries.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
PATH_ARG=${1:?usage: crash-log.sh PATH [BYTES]}
WANT=${2:-3000}

bash tools/wsl/attach.sh || exit 1
: > /tmp/crash.txt
off=0
while [ "$off" -lt "$WANT" ]; do
	$RING rf "$PATH_ARG" "$off" 1000 > /tmp/crash-chunk.txt
	if head -c 2 /tmp/crash-chunk.txt | grep -q '^rf'; then
		echo "missing $PATH_ARG at $off"
		break
	fi
	n=$(wc -c < /tmp/crash-chunk.txt)
	cat /tmp/crash-chunk.txt >> /tmp/crash.txt
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "== $PATH_ARG ($(wc -c < /tmp/crash.txt) bytes)"
cat /tmp/crash.txt
