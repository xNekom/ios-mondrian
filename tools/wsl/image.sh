#!/bin/bash
# Build the payload and the boot image from xnu/out/kernel.development.mondrian.
#
#   tools/wsl/image.sh                        # mondrianprevlines=200
#   PREV_ARGS="" tools/wsl/image.sh           # free ~25 bytes of cmdline
#   EXTRA_ARGS="thermalthr=30" tools/wsl/image.sh
#   PREFIX_ARGS="mondrianunlock=1" tools/wsl/image.sh   # an argument the hook must see
#
# iOS gives kern.bootargs 607 bytes: the length is printed, and mkpayload
# refuses anything longer, so a test argument has to come out of something else
# (PREV_ARGS="" drops the previous-boot line count).
#
# **Arguments at the end of the line are not safe.** Measured 2026-11-17: the
# payload's line ended `... mondrianreset=0  mondrianunlock=1` and the kernel's
# `kern.bootargs` read 631 bytes ending `... mondrianreset=0
# mondrianprevlines=200  shim0=8785 shim1=1292 shim2=6778 shim3=7456` -- the
# shim writes its own arguments over the tail, so an argument appended last is
# gone before any driver or hook reads it, and the only symptom is that the
# code behind it behaves as if it was never passed. Anything the *userland* hook
# has to see goes in PREFIX_ARGS, at the front.
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
