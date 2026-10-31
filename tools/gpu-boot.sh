#!/bin/bash
# Boot a temporary kernel image, wait for the phone to come back and pull the
# kernel ring: the whole GPU loop in one command, with real timeouts.
#
#   tools/gpu-boot.sh IMAGE.img [SECONDS]
#
# IMAGE.img is a boot image made by tools/phone-deploy.sh. The phone must be in
# fastboot (the bootloader, not fastbootd: `fastboot boot` does not exist
# there). The script:
#   1. waits up to 30 s for fastboot, and switches a fastbootd back to the
#      bootloader when it finds one;
#   2. `fastboot boot`s the image;
#   3. waits up to SECONDS (default 240) for the phone to come back to fastboot
#      (the kernel resets there at mondrianreset) or to recovery;
#   4. pulls /dev/block/sda37's ring over adb and decodes it.
#
# Every wait is a poll with a deadline, because macOS has no `timeout` and a
# bare fastboot can block forever on a wedge.
set -u
image=${1:?usage: tools/gpu-boot.sh IMAGE.img [SECONDS]}
limit=${2:-240}
here=$(cd "$(dirname "$0")/.." && pwd)
out=${TMPDIR:-/tmp}

fastboot_devices() { fastboot devices 2>/dev/null | grep -c fastboot; }
adb_devices() { adb devices 2>/dev/null | grep -c recovery; }

deadline=$((SECONDS + 30))
while [ $SECONDS -lt $deadline ] && [ "$(fastboot_devices)" = 0 ]; do sleep 2; done
if [ "$(fastboot_devices)" = 0 ]; then
	echo "no fastboot: power-cycle the phone into FASTBOOT" >&2
	exit 2
fi

# fastbootd answers getvar after a while; a bootloader answers at once.
fastboot getvar is-userspace > "$out/gpu-boot.getvar" 2>&1 &
probe=$!
sleep 6
kill -9 $probe 2>/dev/null
if grep -q 'is-userspace: yes' "$out/gpu-boot.getvar" 2>/dev/null; then
	echo "== fastbootd: switching to the bootloader"
	fastboot reboot bootloader >/dev/null 2>&1
	deadline=$((SECONDS + 40))
	while [ $SECONDS -lt $deadline ]; do
		[ "$(fastboot_devices)" != 0 ] && break
		sleep 2
	done
fi

echo "== booting $image"
fastboot boot "$image" > "$out/gpu-boot.boot" 2>&1 &
bootpid=$!
sleep 20
kill -9 $bootpid 2>/dev/null
head -1 "$out/gpu-boot.boot"

# The kernel resets at mondrianreset; before that there is no adb and no
# fastboot on the bus at all, which is normal.
echo "== waiting up to $limit s for the phone"
deadline=$((SECONDS + limit))
while [ $SECONDS -lt $deadline ]; do
	if [ "$(fastboot_devices)" != 0 ] || [ "$(adb_devices)" != 0 ]; then
		echo "== back after $SECONDS s"
		break
	fi
	sleep 5
done

if [ "$(fastboot_devices)" != 0 ]; then
	fastboot reboot recovery >/dev/null 2>&1
	deadline=$((SECONDS + 60))
	while [ $SECONDS -lt $deadline ] && [ "$(adb_devices)" = 0 ]; do sleep 2; done
fi
if [ "$(adb_devices)" = 0 ]; then
	echo "no recovery: power-cycle the phone, the ring is on userdata" >&2
	exit 3
fi

adb kill-server >/dev/null 2>&1
adb start-server >/dev/null 2>&1
sleep 2
for attempt in 1 2 3; do
	adb exec-out "dd if=/dev/block/sda37 bs=4096 skip=58615290 count=1025 2>/dev/null" > "$out/gpu-boot.ring"
	size=$(stat -f%z "$out/gpu-boot.ring" 2>/dev/null || echo 0)
	[ "$size" -eq 4198400 ] && break
	sleep 3
done
if [ "$size" -ne 4198400 ]; then
	echo "ring pull failed ($size bytes)" >&2
	exit 4
fi
"$here/tools/decode-mondrian-log.py" "$out/gpu-boot.ring" > "$out/gpu-boot.log" 2>&1
echo "== $out/gpu-boot.log ($(grep -ac . "$out/gpu-boot.log") lines)"
