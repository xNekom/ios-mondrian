#!/bin/bash
# Put the touch image where the kernel reads it: a 256 KiB area in front of the
# log ring at the end of userdata, so the driver needs no file system.
#
#   tools/flash-touch-firmware.sh FIRMWARE.bin [CONFIG_GROUP.bin]
#
# The config group defaults to goodix_cfg_group_m11a.bin next to the firmware.
# tools/mk-touch-blob.py repacks both files into the single blob the kernel
# expects (firmware package plus the config as a seventh section). Needs the
# phone in a recovery with adb (OrangeFox); writes nothing else in userdata.
set -euo pipefail

blob=${1:?usage: flash-touch-firmware.sh FIRMWARE.bin [CONFIG_GROUP.bin]}
[ -f "$blob" ] || { echo "error: $blob not found" >&2; exit 1; }
cfg=${2:-$(dirname "$blob")/goodix_cfg_group_m11a.bin}
[ -f "$cfg" ] || { echo "error: $cfg not found" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
image=$(mktemp /tmp/touch-blob.XXXXXX)
"$here/mk-touch-blob.py" "$blob" "$cfg" "$image"

bytes=$(wc -c < "$image" | tr -d ' ')
# 64 blocks, in step with MONDRIAN_FW_BLOCKS in bsd/dev/mondrian_ufs.c.
if [ "$bytes" -gt $((64 * 4096)) ]; then
	echo "error: the blob is larger than the 64-block area" >&2
	exit 1
fi

dev=/dev/block/by-name/userdata
sectors=$(adb shell "cat /sys/class/block/\$(basename \$(readlink -f $dev))/size" | tr -d '\r')
case "$sectors" in
''|*[!0-9]*) echo "error: cannot read the size of $dev" >&2; exit 1 ;;
esac
# sysfs counts 512-byte sectors; the ring is the last 1025 4 KiB blocks.
seek=$((sectors / 8 - 1025 - 64))
echo "userdata is $((sectors / 8)) blocks; writing $bytes bytes at block $seek"

tmp=$(mktemp /tmp/touch-fw.XXXXXX)
cp "$image" "$tmp"
rm -f "$image"
adb push "$tmp" /tmp/touch-fw.bin >/dev/null
rm -f "$tmp"
adb shell "dd if=/tmp/touch-fw.bin of=$dev bs=4096 seek=$seek conv=fsync 2>&1 | tail -1"
adb shell 'rm -f /tmp/touch-fw.bin'
echo "done; boot the kernel and look for 'MONDRIAN TOUCH: firmware' in the log"
