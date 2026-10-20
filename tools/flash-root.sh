#!/bin/bash
# Flash the iOS root into the userdata partition. Nothing else.
#
#   tools/flash-root.sh ios16-root.simg
#
# This is the only destructive step of the project and the only one that
# changes the phone: it erases the Android user data (the partition, not the
# system). The bootloader, the recovery, the modem and the persist partition
# are never touched, so a mistake here is recoverable by reflashing Android.
#
# Flashing anything else (boot, init_boot, dtbo, vbmeta, abl, tz) would risk
# a hard brick. This script refuses to do it.
set -euo pipefail

image=${1:?usage: flash-root.sh ROOT.simg}

# The partition the iOS root goes into. Do not change this.
partition=userdata

case "$image" in
	*.img|*.simg) ;;
	*) echo "error: $image does not look like a partition image" >&2; exit 1 ;;
esac

if [ ! -f "$image" ]; then
	echo "error: $image not found" >&2
	exit 1
fi

# A fastboot that is not in fastboot mode would write to the wrong place.
if ! fastboot devices | grep -q .; then
	echo "error: no device in fastboot mode (the phone must be in fastboot)" >&2
	exit 1
fi

echo "About to ERASE the $partition partition of the phone with:"
echo "  $image ($(du -h "$image" | cut -f1))"
echo "This deletes the Android user data. The bootloader, recovery, modem and"
echo "persist are not touched."
printf "Type 'yes' to continue: "
read -r answer
[ "$answer" = yes ] || { echo "aborted"; exit 1; }

# -S 512M: the big write needs the extra buffer, or the transfer stalls.
fastboot -S 512M flash "$partition" "$image"

echo
echo "The $partition partition now holds the iOS root."
echo "Boot it with: fastboot boot shim/out/shim-boot.img"
echo "(temporary: nothing was written to the boot partitions)"
