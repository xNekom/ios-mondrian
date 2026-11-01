#!/bin/bash
# Refresh the iOS root the safe way: dump the phone's partition first, repair
# it, install the userland, and push back only what changed.
#
# A push compares a base image against a modified one, so the base has to be
# the phone's current content: the kernel mounts the root read-write
# (rootrw=1) and writes to it on every boot, and pushing an older image over
# those writes leaves the volume inconsistent (measured: hfs_mark_inconsistent
# and a dylib the loader reports as "not a mach-o file").
set -euo pipefail
cd /mnt/c/Users/Pedro/Documents/GitHub/ios-mondrian || exit 1
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
image=${1:-/root/ios/work.img}
before=${2:-/root/ios/work.before.img}

echo "== dumping the partition (16 GiB)"
"$ADB" exec-out "dd if=/dev/block/sda37 bs=1M count=16384 2>/dev/null" >"$image"
ls -l "$image"

echo "== fsck"
fsck.hfsplus -fy "$image" 2>&1 | tail -3
fsck.hfsplus -fn "$image" 2>&1 | tail -2

echo "== base copy for the push"
cp "$image" "$before"

echo "== install"
bash tools/wsl/install-dylibs.sh "$image" \
	--gl out/gpu/mondrian-gl.dylib \
	--inject out/gpu/mondrian-inject.dylib \
	--mesa out/mesa/stage 2>&1 | tail -4

echo "== push"
ADB=$ADB timeout 1800 python3 tools/wsl/push-blocks.py "$before" "$image" 2>&1 | tail -3
