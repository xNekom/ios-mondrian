#!/bin/bash
# Boot an image on the phone with fastboot, without writing any partition.
#
#   tools/phone-boot.sh              # build the image and boot it
#   tools/phone-boot.sh <image>      # boot an image that is already built
#   tools/phone-boot.sh --wait       # boot it and wait for the phone to come
#                                    # back (it panics and the bootloader
#                                    # reboots it; see phone-cycle.sh)
#
# The phone has to be in fastboot (power + volume down). Nothing is
# flashed: fastboot boot loads the image in RAM and runs it, so the boot
# partition keeps whatever it had.
#
# The ABL's fastboot USB stack hangs from time to time, so the command
# runs with a time limit instead of being left there.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=${1:-/tmp/boot-mondrian.img}
WAIT=0
if [ "${1:-}" = "--wait" ]; then
	WAIT=1
	shift
	IMAGE=${1:-/tmp/boot-mondrian.img}
fi
command -v fastboot >/dev/null || { echo "falta fastboot" >&2; exit 1; }

if [ "$WAIT" = 1 ]; then
	exec bash tools/phone-cycle.sh "$IMAGE"
fi

if [ ! -f "$IMAGE" ]; then
	echo "== no hay imagen en $IMAGE: se construye"
	bash tools/phone-deploy.sh build
fi

# The A/B retry budget belongs to the bootloader: it takes one attempt per
# boot and the port's kernel never reports a boot as successful, so after
# seven tries ABL marks the active slot unbootable. It then refuses *every*
# boot image -- the stock recovery included -- with "Failed to load/
# authenticate boot image: Not Found", which reads like a bad image and is
# not. Activating the slot again resets the flag and the budget; it writes no
# partition.
slot=$(fastboot getvar current-slot 2>&1 | tr -d '\r' | sed -n 's/^current-slot: *//p')
if [ -n "$slot" ]; then
	unbootable=$(fastboot getvar "slot-unbootable:$slot" 2>&1 | tr -d '\r' |
		sed -n "s/^slot-unbootable:$slot: *//p")
	if [ "$unbootable" = yes ]; then
		echo "== slot $slot marcado no arrancable: fastboot set_active $slot"
		fastboot set_active "$slot" >/dev/null
	fi
fi

echo "== arrancando $IMAGE (fastboot boot, no escribe nada)"
( fastboot boot "$IMAGE" > /tmp/fb-boot.txt 2>&1 ) &
pid=$!
for _ in $(seq 1 45); do
	sleep 1
	kill -0 $pid 2>/dev/null || break
done
kill -9 $pid 2>/dev/null || true
cat /tmp/fb-boot.txt
if grep -q 'Failed to load/authenticate boot image' /tmp/fb-boot.txt; then
	echo "== ABL rechaza la imagen: el slot casi seguro volvio a agotar sus" >&2
	echo "   reintentos; 'fastboot set_active $slot' lo rearma y no escribe nada." >&2
fi
echo "== el movil deberia mostrar la consola del shim y la del kernel"
