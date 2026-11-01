#!/bin/bash
# After a shim boot: wait for the phone to come back, boot the installed
# recovery and pull the console ring.
#
#   bash tools/wsl/collect-ring.sh OUT.txt [MAX_WAIT]
#
# The kernel writes the ring during its run and resets to fastboot when it
# gives up, so this waits for fastboot (or for a recovery that is already up),
# boots recovery, and reads the last 4 MiB of userdata. The Windows adb and
# fastboot are used: the USB device is only visible to them.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
out=${1:?usage: collect-ring.sh OUT.txt [max-wait-seconds]}
max_wait=${2:-900}
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
FASTBOOT=${FASTBOOT:-/mnt/c/platform-tools/fastboot.exe}
[ -x "$ADB" ] || { echo "error: no adb at $ADB" >&2; exit 1; }
[ -x "$FASTBOOT" ] || { echo "error: no fastboot at $FASTBOOT" >&2; exit 1; }

state() {
	if "$FASTBOOT" devices 2>/dev/null | grep -q .; then
		echo fastboot
	elif "$ADB" devices 2>/dev/null | grep -q 'recovery$'; then
		echo recovery
	else
		echo running
	fi
}

echo "== waiting up to ${max_wait}s for fastboot or recovery"
waited=0
while [ "$waited" -lt "$max_wait" ]; do
	s=$(state)
	if [ "$s" != running ]; then
		echo "== $s after ${waited}s"
		break
	fi
	sleep 10
	waited=$((waited + 10))
done
if [ "$(state)" = running ]; then
	echo "== still running (the kernel has not reset); no ring yet" >&2
	exit 1
fi
if [ "$(state)" = fastboot ]; then
	echo "== booting recovery"
	"$FASTBOOT" reboot recovery >/dev/null 2>&1
fi
for i in $(seq 1 60); do
	[ "$(state)" = recovery ] && break
	sleep 5
done
ADB=$ADB bash tools/wsl/pull-ring.sh "$out"
