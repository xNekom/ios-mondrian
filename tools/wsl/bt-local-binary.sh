#!/bin/bash
# Which local copy of the iOS root carries the same bluetoothd the phone runs?
# The phone's first 9000 bytes are in out/bt-head.bin, so a byte compare answers
# it without trusting a version string; a match means the local file can be
# analysed instead of pulled over the ring.
set -u
cd "$(dirname "$0")/../.." || exit 1

for f in \
	/root/btbin/iOSRoot/usr/sbin/bluetoothd \
	/root/ios-bt/iOSRoot/usr/sbin/bluetoothd \
	/root/bt/iOSRoot/usr/sbin/bluetoothd \
	/root/btext/bluetoothd; do
	[ -f "$f" ] || continue
	printf '%s ' "$f"
	sz=$(stat -c %s "$f")
	if head -c 9000 "$f" | cmp -s - out/bt-head.bin; then
		echo "MATCH size $sz"
	else
		head4=$(od -An -tx1 -N4 "$f" | tr -d ' \n')
		echo "differ size $sz magic $head4"
	fi
done
