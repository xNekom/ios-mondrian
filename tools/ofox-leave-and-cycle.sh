#!/bin/bash
# Leave the recovery, put the phone in fastboot, and run a kernel cycle.
#
#   tools/ofox-leave-and-cycle.sh /root/cmds-force.txt
#
# The recovery answers on adb, not on the ring, so cycle.sh alone cannot get the
# phone out of it: `adb reboot bootloader` is the one step it does not do.
set -u
cd /mnt/c/Users/Pedro/Documents/GitHub/ios-mondrian || exit 1

if adb devices 2>/dev/null | grep -q -w device; then
	echo "== leaving recovery"
	adb reboot bootloader > /dev/null 2>&1
fi
for i in $(seq 1 20); do
	sleep 5
	/mnt/c/platform-tools/fastboot.exe devices 2>/dev/null | grep -q fastboot && break
done
/mnt/c/platform-tools/fastboot.exe devices 2>/dev/null | grep -q fastboot || {
	echo "no fastboot after the recovery" >&2
	exit 1
}
exec bash tools/wsl/cycle.sh "$@"
