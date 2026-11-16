#!/bin/bash
# Build the payload and the boot image from xnu/out/kernel.development.mondrian.
#
#   tools/wsl/image.sh                        # mondrianprevlines=200
#   PREV_ARGS="" tools/wsl/image.sh           # free ~25 bytes of cmdline
#   EXTRA_ARGS="thermalthr=30" tools/wsl/image.sh
#
# iOS gives kern.bootargs 607 bytes: the length is printed, and mkpayload
# refuses anything longer, so a test argument has to come out of something else
# (PREV_ARGS="" drops the previous-boot line count).
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
CM="$CM $PREV ${EXTRA_ARGS:-}"
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
