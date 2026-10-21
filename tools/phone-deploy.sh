#!/bin/bash
# Deploy a kernel to the phone over adb, without the bootloader's fastboot.
#
# The ABL's fastboot USB stack is unreliable on this phone (it drops the
# transfer of anything bigger than a few hundred kilobytes, while adb over
# the recovery's own USB stack is fine). So the image goes over adb and the
# recovery writes it to the boot partition, and the phone then boots it
# the normal way: no fastboot transfer at all, and the bootloader leaves
# the UFS powered, which the root device driver needs.
#
#   tools/phone-deploy.sh build            # build the payload and the image
#   tools/phone-deploy.sh push             # copy it to the phone
#   tools/phone-deploy.sh install          # write it to the boot partition
#   tools/phone-deploy.sh backup           # save the original boot image
#   tools/phone-deploy.sh reboot           # restart the phone
#
# The original boot image is kept in the phone (/data/local/tmp/boot-orig.img)
# so the Android installation can be put back.
set -euo pipefail
cd "$(dirname "$0")/.."

BOARD=mondrian
KERNEL=${KERNEL:-}
ADT=${ADT:-/tmp/adt-mondrian.dtb}
PAYLOAD=${PAYLOAD:-/tmp/payload-phone.bin}
IMAGE=${IMAGE:-/tmp/boot-mondrian.img}
RAMDISK=${RAMDISK:-/tmp/phone-ramdisk}
REMOTE=/data/local/tmp/boot-mondrian.img
BLOCK=/dev/block/by-name/boot

need() {
	command -v "$1" >/dev/null || { echo "falta $1" >&2; exit 1; }
}

case "${1:-}" in
build)
	need adb
	if [ -z "$KERNEL" ]; then
		# The newest kernel the CI produced.
		KERNEL=$(ls -t /tmp/mk*/kernel.development.mondrian 2>/dev/null | head -1)
	fi
	[ -f "$KERNEL" ] || { echo "no hay kernel; baja el artefacto del CI" >&2; exit 1; }
	[ -f "$RAMDISK" ] || { printf '#!/bin/sh\nexec /bin/sh\n' > "$RAMDISK"; }
	python3 tools/mkadt.py --board "$BOARD" "$ADT"
	python3 tools/mkpayload.py "$KERNEL" "$ADT" "$PAYLOAD" --board "$BOARD" \
		--ramdisk "$RAMDISK"
	# The shim image: the loader plus the payload, as a boot image.
	(cd shim && BOARD=$BOARD CROSS=${CROSS:-aarch64-elf-} \
		EXTRA_CFLAGS="-DSHIM_NO_UFS" ./build.sh "$PAYLOAD")
	cp shim/out/shim-boot.img "$IMAGE"
	ls -l "$IMAGE" "$PAYLOAD"
	;;
push)
	need adb
	adb wait-for-device
	adb push "$IMAGE" "$REMOTE"
	adb shell "ls -l $REMOTE"
	;;
install)
	need adb
	adb wait-for-device
	# The original goes first: the boot partition is the Android one.
	if ! adb shell "ls /data/local/tmp/boot-orig.img" >/dev/null 2>&1; then
		echo "guardando la imagen original de $BLOCK"
		adb shell "dd if=$BLOCK of=/data/local/tmp/boot-orig.img bs=4M"
	fi
	adb shell "dd if=$REMOTE of=$BLOCK bs=4M conv=fsync"
	adb shell "sync"
	echo "escrito $BLOCK; reinicia el telefono"
	;;
backup)
	need adb
	adb wait-for-device
	adb shell "dd if=$BLOCK of=/data/local/tmp/boot-orig.img bs=4M"
	adb shell "ls -l /data/local/tmp/boot-orig.img"
	;;
reboot)
	adb reboot
	;;
*)
	echo "uso: $0 {build|push|install|backup|reboot}" >&2
	exit 2
	;;
esac
