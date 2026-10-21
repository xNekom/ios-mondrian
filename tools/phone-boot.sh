#!/bin/bash
# Boot an image on the phone with fastboot, without writing any partition.
#
#   tools/phone-boot.sh              # build the image and boot it
#   tools/phone-boot.sh <image>      # boot an image that is already built
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
command -v fastboot >/dev/null || { echo "falta fastboot" >&2; exit 1; }

if [ ! -f "$IMAGE" ]; then
	echo "== no hay imagen en $IMAGE: se construye"
	bash tools/phone-deploy.sh build
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
echo "== el movil deberia mostrar la consola del shim y la del kernel"
