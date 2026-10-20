#!/bin/bash
# Probe a phone in fastboot: read what the bootloader says and boot the shim
# once, without flashing anything.
#
#   tools/probe-mondrian.sh
#
# It only reads (getvar) and does a temporary boot (fastboot boot), which
# leaves every partition alone: the phone comes back with a reboot.
#
# What the phone shows on screen (photograph it):
#
#   SHIM   board mondrian (SM8475)
#   FB     at=B8000000 size=02B00000
#   UFS    at=01D84000 size=00003000
#   FACT memory reg0 0x… 0x…
#   FACT reg /soc/intc 0x17100000 0x10000 0x17180000 0x200000
#   …
#   LOADER no initrd in /chosen
#   UFS    probe skipped (SHIM_NO_UFS)
#
# Those FACT lines are what tools/mkadt.py --facts needs to fill in the
# memory map of the board.
set -euo pipefail
cd "$(dirname "$0")/.."

img=shim/out/shim-boot.img

if [ ! -f "$img" ]; then
	echo "error: $img not found. Build it with:" >&2
	echo "  BOARD=mondrian CROSS=aarch64-elf- EXTRA_CFLAGS=-DSHIM_NO_UFS shim/build.sh" >&2
	exit 1
fi

echo "== devices =="
fastboot devices || true
if [ -z "$(fastboot devices 2>/dev/null)" ]; then
	echo "no device in fastboot mode" >&2
	exit 1
fi

echo
echo "== device information (read only) =="
for v in product current-slot unlocked secure version-bootloader \
	version-baseband serialno; do
	printf '%-20s ' "$v"
	fastboot getvar "$v" 2>&1 | sed -n 's/.*: //p' | head -1 || true
done

echo
echo "== booting the shim (temporary, nothing is written) =="
fastboot boot "$img"

cat <<'EOF'

The phone now shows the shim console (a red screen with text). Photograph
it: the FACT lines carry the memory map and the addresses of the
peripherals, which is what the port needs next.

The shim waits three minutes and reboots by itself.
EOF
