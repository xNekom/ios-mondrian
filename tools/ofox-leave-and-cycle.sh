#!/bin/bash
# Leave the recovery, put the phone in fastboot, and run a kernel cycle.
#
#   tools/ofox-leave-and-cycle.sh @/root/cmds-force.txt
#
# The recovery answers on adb, not on the ring, so cycle.sh alone cannot get the
# phone out of it. `adb reboot bootloader` is ignored by OrangeFox; a shell-level
# `reboot bootloader` is obeyed, and that is the difference between a phone that
# keeps coming back to the recovery menu and one that reaches fastboot.
set -u
cd "$(dirname "$0")/.." || exit 1

if adb devices 2>/dev/null | grep -q -w recovery; then
	echo "== leaving recovery"
	timeout 20 adb shell 'reboot bootloader' > /dev/null 2>&1
fi
bash tools/wsl/to-fastboot.sh || exit 1
exec bash tools/wsl/cycle.sh "$@"
