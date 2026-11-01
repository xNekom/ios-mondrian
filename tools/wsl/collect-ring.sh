#!/bin/bash
# After a shim boot: wait for the kernel to reset the phone to fastboot, boot
# the installed recovery, and pull the console ring.
#
#   bash tools/wsl/collect-ring.sh OUT.txt [FASTBOOT_WAIT]
#
# The Windows adb/fastboot are used from WSL: the USB device is only visible to
# them.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
out=${1:?usage: collect-ring.sh OUT.txt [seconds-to-wait]}
wait_s=${2:-150}
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
FASTBOOT=${FASTBOOT:-/mnt/c/platform-tools/fastboot.exe}
[ -x "$ADB" ] || { echo "error: no adb at $ADB" >&2; exit 1; }
[ -x "$FASTBOOT" ] || { echo "error: no fastboot at $FASTBOOT" >&2; exit 1; }

echo "== waiting ${wait_s}s for the kernel to reset to fastboot"
sleep "$wait_s"
for i in $(seq 1 30); do
	if "$FASTBOOT" devices 2>/dev/null | grep -q .; then
		echo "== fastboot is up"
		break
	fi
	if "$ADB" devices 2>/dev/null | grep -q 'recovery$'; then
		echo "== already in recovery"
		break
	fi
	sleep 5
done

if "$FASTBOOT" devices 2>/dev/null | grep -q .; then
	echo "== booting recovery"
	"$FASTBOOT" reboot recovery >/dev/null 2>&1
fi
for i in $(seq 1 60); do
	if "$ADB" devices 2>/dev/null | grep -q 'recovery$'; then
		echo "== recovery adb is up"
		break
	fi
	sleep 5
done

ADB=$ADB bash tools/wsl/pull-ring.sh "$out"
