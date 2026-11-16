#!/bin/bash
# Flash the built image into the iOS slot and reboot into it.
#
#   tools/wsl/flash-image.sh              # build the image, flash boot_<slot>, reboot
#   tools/wsl/flash-image.sh --no-build   # flash shim/out/shim-boot.img as is
#
# This is the fallback when `fastboot boot` is refused. That refusal is real and
# silent in the usual output: "Sending 'boot.img' ... OKAY" is printed even when
# the boot itself comes back "FAILED (remote: 'Failed to load/authenticate boot
# image: Not Found')", so a script that greps for OKAY reports a boot that never
# happened and the phone is left running boot_b -- which reads exactly like a
# kernel that crashes on boot.
#
# Only the iOS slot is written. boot_a keeps stock Android, and a bad image
# leaves fastboot working, so the way back is the same command with another
# image.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
FB=${FB:-/mnt/c/platform-tools/fastboot.exe}
SLOT=${SLOT:-b}
K=xnu/out/kernel.development.mondrian

if [ "${1:-}" != "--no-build" ]; then
	bash tools/wsl/build-kernel.sh > /tmp/flash-build.log 2>&1 || {
		grep -a -n 'error:' /tmp/flash-build.log | tail -5
		exit 1
	}
	bash tools/wsl/image.sh || exit 1
fi
[ -f shim/out/shim-boot.img ] || { echo "no shim/out/shim-boot.img" >&2; exit 1; }

"$FB" devices 2>/dev/null | grep -q fastboot || {
	echo "the phone is not in fastboot (power + volume down)" >&2
	exit 1
}
CUR=$("$FB" getvar current-slot 2>&1 | sed -n 's/current-slot: *//p' | head -1)
if [ "$CUR" != "$SLOT" ]; then
	echo "current slot is $CUR, refusing to write boot_$SLOT (SLOT=$SLOT)" >&2
	exit 1
fi

echo "== flash boot_$SLOT"
timeout 300 "$FB" flash "boot_$SLOT" "$(wslpath -w "$PWD/shim/out/shim-boot.img")" 2>&1 |
	tail -3
timeout 30 "$FB" reboot 2>&1 | tail -1
echo "== flashed; the ring answers in about three minutes (tools/usb-ring.py pos)"
