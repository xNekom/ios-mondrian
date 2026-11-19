#!/bin/bash
# Build the payload and the boot image from xnu/out/kernel.development.mondrian.
#
#   tools/wsl/image.sh                        # mondrianprevlines=200
#   PREV_ARGS="" tools/wsl/image.sh           # free ~25 bytes of cmdline
#   EXTRA_ARGS="thermalthr=30" tools/wsl/image.sh
#   PREFIX_ARGS="mondrianunlock=1" tools/wsl/image.sh   # an argument the hook must see
#
# A duplicate key is last-wins in XNU (measured 2026-11-19): `EXTRA_ARGS`
# overrides a key the board already carries, `PREFIX_ARGS` loses to it.
#
# iOS gives kern.bootargs 607 bytes: the length is printed, and mkpayload
# refuses anything longer, so a test argument has to come out of something else
# (PREV_ARGS="" drops the previous-boot line count).
#
# The shim appends nothing to the line any more: its own marks (the four phases
# in milliseconds) go to the console, because at 631 bytes the read above failed
# with ENOMEM, `watchdogd` aborted on every launch and launchd respawned it 34
# times in one boot. Measured 2026-11-18 with this script: the kernel logs
# `args 607 bytes` and the abort count is 0. The tail of the line is therefore
# the payload's own last argument, and `EXTRA_ARGS` is safe to use.
#
# NEVER pipe this script through head/tail: SIGPIPE kills it after the first
# line, the old image stays on disk, and the phone boots the previous kernel
# while the new command looks like it does not exist. That cost two boots.
set -euo pipefail
cd "$(dirname "$0")/../.."

CM=$(python3 -c "from tools.boards import BOARDS; print(BOARDS['mondrian'].cmdline)")
if [ -z "${PREV_ARGS+x}" ]; then
	PREV="mondrianprevlines=200"
else
	PREV="$PREV_ARGS"
fi
CM="${PREFIX_ARGS:+$PREFIX_ARGS }$CM $PREV ${EXTRA_ARGS:-}"
echo "cmdline: ${#CM} bytes: $CM"
python3 tools/mkpayload.py xnu/out/kernel.development.mondrian \
	shim/out/mondrian.adt shim/out/payload.bin --board mondrian \
	--cmdline "$CM" > /tmp/mkpayload.log 2>&1 || {
	tail -20 /tmp/mkpayload.log
	exit 1
}
BOARD=mondrian SMALL_SHIM=1 DTB=dtb/mondrian-live.dtb \
	shim/build.sh shim/out/payload.bin > /tmp/shim.log 2>&1 || {
	tail -20 /tmp/shim.log
	exit 1
}
ls -l shim/out/shim-boot.img
