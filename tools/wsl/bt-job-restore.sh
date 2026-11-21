#!/bin/bash
# Put com.apple.bluetoothd.plist back the way the stock ROM shipped it. The
# StandardErrorPath key an earlier experiment added proved inert (the spawn path
# ignores it; the shim's own log is the channel that works), so the job file
# should not stay modified.
#
# The backup lives on the phone because the edit was made there. Reading it back
# is only safe if `rf` returns the exact bytes: the script first proves that by
# reading the head of the deployed shim dylib and comparing it with the local
# copy, and aborts before writing anything if they differ.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
JOB=/System/Library/LaunchDaemons/com.apple.bluetoothd.plist
BACKUP=/private/var/vm/bt-job-original.plist

bash tools/wsl/attach.sh || exit 1

echo "== is rf byte exact?"
$RING rf /private/var/vm/mondrian-bt.dylib 0 1000 > /tmp/rf-head.bin
head -c 1000 out/gpu/mondrian-bt.dylib > /tmp/local-head.bin
if ! cmp -s /tmp/rf-head.bin /tmp/local-head.bin; then
	echo "rf is not byte exact; refusing to write the job file"
	exit 1
fi
echo "yes"

echo "== fetch the backup"
: > /tmp/bt-job-orig.plist
off=0
while [ "$off" -lt 4000 ]; do
	$RING rf "$BACKUP" "$off" 1000 > /tmp/bt-chunk.bin
	if head -c 2 /tmp/bt-chunk.bin | grep -q '^rf'; then
		echo "missing $BACKUP at $off"
		exit 1
	fi
	n=$(wc -c < /tmp/bt-chunk.bin)
	cat /tmp/bt-chunk.bin >> /tmp/bt-job-orig.plist
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done
echo "$(wc -c < /tmp/bt-job-orig.plist) bytes"
head -c 40 /tmp/bt-job-orig.plist
echo

echo "== write it back"
$RING wfile "$JOB" /tmp/bt-job-orig.plist || exit 1
$RING wait 3
echo "== keys now"
bash tools/wsl/bt-job-info.sh
