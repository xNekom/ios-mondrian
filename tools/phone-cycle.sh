#!/bin/bash
# Boot an image on the phone and wait for it to come back on its own.
#
#   tools/phone-cycle.sh                 # boot the current image and wait
#   tools/phone-cycle.sh /tmp/foo.img    # boot another image
#   tools/phone-cycle.sh --wait          # only wait for the phone to be back
#
# Why this exists: the kernel panics and the phone stops answering (no adb,
# no fastboot). The bootloader takes it back with its watchdog and the phone
# comes up in fastboot again, but nobody has to hold the buttons to get
# there. This script boots the image and then waits for the phone to show up
# again, in fastboot or in Android; if it comes up in Android it asks it to
# reboot into the bootloader (adb over wifi, see NOTES.md).
#
# It never writes a partition: `fastboot boot` only loads the image in RAM.
set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE=/tmp/boot-mondrian.img
TIMEOUT=${TIMEOUT:-240}
WAIT_ONLY=0
for a in "$@"; do
	case "$a" in
	--wait) WAIT_ONLY=1 ;;
	-*) echo "usage: $0 [--wait] [image]" >&2; exit 2 ;;
	*) IMAGE=$a ;;
	esac
done

command -v fastboot >/dev/null || { echo "falta fastboot" >&2; exit 1; }

# The phone's serial in fastboot. It is also how the phone is told apart
# from the other devices on the network: adb over wifi reaches every phone
# in the house, so adb is only ever used with an explicit serial.
PHONE_SERIAL=${PHONE_SERIAL:-7e63c267}

phone_fastboot() {
	fastboot devices 2>/dev/null | grep -q "^${PHONE_SERIAL}[[:space:]]"
}

phone_android() {
	# The mondrian's adb name over wifi (the mDNS name carries the serial).
	local dev="adb-${PHONE_SERIAL}-HV6ZYc._adb-tls-connect._tcp"
	adb devices 2>/dev/null | grep -q "^${dev}[[:space:]].*device$"
}

if [ "$WAIT_ONLY" = 0 ]; then
	[ -f "$IMAGE" ] || { echo "no hay imagen en $IMAGE" >&2; exit 1; }
	echo "== arrancando $IMAGE (fastboot boot, no escribe nada)"
	( fastboot -s "$PHONE_SERIAL" boot "$IMAGE" > /tmp/fb-boot.txt 2>&1 ) &
	pid=$!
	for _ in $(seq 1 45); do
		sleep 1
		kill -0 $pid 2>/dev/null || break
	done
	kill -9 $pid 2>/dev/null || true
	cat /tmp/fb-boot.txt
fi

echo "== esperando a que el movil vuelva (max ${TIMEOUT}s)"
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
	if phone_fastboot; then
		echo "== el movil esta en fastboot"
		exit 0
	fi
	if phone_android; then
		echo "== el movil volvio a Android: pidiendo el bootloader"
		local dev="adb-${PHONE_SERIAL}-HV6ZYc._adb-tls-connect._tcp"
		adb -s "$dev" reboot bootloader >/dev/null 2>&1
		sleep 10
		continue
	fi
	sleep 5
done

echo "== el movil no volvio en ${TIMEOUT}s" >&2
exit 1
