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

# The phone is A/B: the active slot decides which boot partition is written.
slot() {
	adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r\n'
}

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
	# The PMK8350 RTC has never been set, so the kernel takes the host's UTC
	# time from the command line (`bsd/dev/mondrian_clock.c` reads
	# mondriantime, in seconds since 1970). Stamped at build time.
	: "${CMDLINE:=$(python3 -c "from tools.boards import BOARDS; print(BOARDS['$BOARD'].cmdline)")}"
	CMDLINE="$CMDLINE mondriantime=$(date +%s)"
	python3 tools/mkadt.py --board "$BOARD" "$ADT"
	python3 tools/mkpayload.py "$KERNEL" "$ADT" "$PAYLOAD" --board "$BOARD" \
		--ramdisk "$RAMDISK" ${CMDLINE:+--cmdline "$CMDLINE"}
	# The shim image: the loader plus the payload, as a boot image.
	# SMALL_SHIM keeps the diagnostics out: the facts dump fills the whole
	# screen and the lines that matter (the loader's verdict, the kernel's
	# early console) scroll away.
	(cd shim && BOARD=$BOARD CROSS=${CROSS:-aarch64-elf-} \
		SMALL_SHIM=1 ./build.sh "$PAYLOAD")
	cp shim/out/shim-boot.img "$IMAGE"
	ls -l "$IMAGE" "$PAYLOAD"
	;;
logview)
	# The log viewer: reads the persistent console log (xnu 0096) out of the
	# end of userdata, prints the last screenful and stops there. Nothing is
	# written to the phone; start it with `fastboot boot $IMAGE`.
	[ -f "$PAYLOAD" ] || { echo "no hay payload: ejecuta build primero" >&2; exit 1; }
	(cd shim && BOARD=$BOARD CROSS=${CROSS:-aarch64-elf-} LOGVIEW=1 ./build.sh "$PAYLOAD")
	cp shim/out/shim-boot.img "$IMAGE"
	ls -l "$IMAGE"
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
	BLOCK=/dev/block/by-name/boot$(slot)
	ORIG=/data/local/tmp/boot-orig$(slot).img
	# boot_a keeps the stock Android image; the shim boots from slot b and
	# nothing here is allowed to break that escape hatch. To break this
	# rule on purpose (there is no known need), set BOOT_A=1 and have a
	# verified copy of boot_a at backup/boot_a-original.img (sha256
	# 39a24660fe9c2ebbf3f074b783a240c0d86eaa42fc241b04394706e00bdadb74).
	if [ "$(slot)" = "a" ]; then
		if [ "${BOOT_A:-0}" != 1 ]; then
			echo "rechazado: escribiria boot_a (el Android de escape). BOOT_A=1 lo permite a despropósito." >&2
			exit 1
		fi
	fi
	# The original goes first: the boot partition is the Android one.
	if ! adb shell "ls $ORIG" >/dev/null 2>&1; then
		echo "guardando la imagen original de $BLOCK"
		adb shell "dd if=$BLOCK of=$ORIG bs=4M"
	fi
	adb shell "dd if=$REMOTE of=$BLOCK bs=4M conv=fsync"
	adb shell "sync"
	echo "escrito $BLOCK; reinicia el telefono"
	;;
backup)
	need adb
	adb wait-for-device
	BLOCK=/dev/block/by-name/boot$(slot)
	# Keep it on the phone too (the recovery trick of NOTES.md reads it
	# without USB), but the durable copy comes off the phone: /data is
	# the partition this port rewrites and already lost the earlier
	# copies once.
	adb shell "dd if=$BLOCK of=/data/local/tmp/boot-orig$(slot).img bs=4M"
	adb shell "ls -l /data/local/tmp/boot-orig$(slot).img"
	DEST="backup/boot$(slot)-$(date +%Y%m%d-%H%M).img"
	adb pull /data/local/tmp/boot-orig$(slot).img "$DEST"
	shasum -a 256 "$DEST" | tee -a backup/SHA256SUMS
	;;
reboot)
	adb reboot
	;;
*)
	echo "uso: $0 {build|push|install|backup|reboot}" >&2
	exit 2
	;;
esac
