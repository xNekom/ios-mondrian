#!/bin/bash
# Ask the vendor kernel what the hardware is, in one boot.
#
#   tools/vendor-dump.sh                     # boot OrangeFox from RAM and dump
#   tools/vendor-dump.sh --no-boot           # dump from whatever is on adb now
#   OFOX=/path/ofox.img tools/vendor-dump.sh
#
# A recovery image booted with `fastboot boot` writes nothing: it runs the
# vendor kernel, which already has every driver this phone needs, and its shell
# answers in one minute what an XNU boot can only guess at -- regulator
# voltages and votes, the clock and interconnect tree, the SPMI map, the thermal
# zones, panel timings, UFS gear and the haptics driver's own debugfs.
#
# Measured against the ABL here: `fastboot boot` refuses OrangeFox's own image
# with "Failed to load/authenticate boot image: Bad Buffer Size" (36 MB), and
# flashing it to boot_b then reboot does not boot it either -- the phone lands
# in fastboot again. Whatever image this phone used before had been repacked;
# there is no recipe for it in the tree. Until one exists, flashing boot_b
# destroys the iOS image, so restore it in the same breath:
#   fastboot flash boot_b shim/out/shim-boot.img && fastboot reboot
#
# Everything lands in $OUT (default /root/vendor-dump), never in git: these are
# device dumps. Grep them; do not paste them into a doc. The point of a value is
# to become a constant in tools/boards.py or shim/board.h, or a line in NOTES.md
# with its source.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OFOX=${OFOX:-/mnt/c/Users/Pedro/AppData/Local/Temp/opencode/ofox-boot-b-complete.img}
OUT=${OUT:-/root/vendor-dump}
FB=${FB:-/mnt/c/platform-tools/fastboot.exe}
BUSID=${BUSID:-7-1}
BOOT=1
[ "${1:-}" = "--no-boot" ] && BOOT=0

if [ "$BOOT" = 1 ]; then
	[ -f "$OFOX" ] || { echo "no recovery image at $OFOX (set OFOX=)" >&2; exit 1; }
	if ! "$FB" devices 2>/dev/null | grep -q fastboot; then
		usbipd.exe attach --wsl --busid "$BUSID" > /dev/null 2>&1
		sleep 5
		echo "== asking the running kernel for fastboot"
		timeout 25 python3 tools/usb-ring.py reboot > /dev/null 2>&1
		for i in $(seq 1 30); do
			sleep 5
			"$FB" devices 2>/dev/null | grep -q fastboot && break
		done
	fi
	"$FB" devices 2>/dev/null | grep -q fastboot || {
		echo "no fastboot: power + volume down" >&2
		exit 1
	}
	echo "== fastboot boot $(basename "$OFOX")"
	timeout 90 "$FB" boot "$(wslpath -w "$OFOX")" 2>&1 | tail -2
fi

echo "== waiting for adb"
adb start-server > /dev/null 2>&1
for i in $(seq 1 40); do
	sleep 5
	# OrangeFox reports its state as "recovery", not "device": a wait for the
	# word "device" times out on a recovery that is already up and answering.
	adb devices | grep -q -w -e device -e recovery && break
done
adb devices | grep -q -w -e device -e recovery || { echo "no adb device" >&2; exit 1; }

mkdir -p "$OUT" || exit 1
run() {
	name=$1
	shift
	adb shell "$*" > "$OUT/$name.txt" 2>&1
	printf '%-22s %s lines\n' "$name" "$(wc -l < "$OUT/$name.txt")"
}

# Identity first: which build answered, so the dump is never mis-filed.
run version 'getprop ro.build.display.id; uname -a; cat /proc/cmdline'
run dmesg 'dmesg'
# Addresses, interrupts and memory the bootloader left behind.
run iomem 'cat /proc/iomem'
run devices 'cat /proc/devices; cat /proc/interrupts'
# Clocks, interconnects and regulators: the votes a driver has to reproduce.
run clk 'cat /sys/kernel/debug/clk/clk_summary'
run icc 'find /sys/kernel/debug/interconnect -name "*.txt" -o -name summary | head -5 | xargs -r cat'
run regulator 'cat /sys/kernel/debug/regulator/regulator_summary'
run regulators 'for r in /sys/class/regulator/*; do echo "== $r"; cat $r/name $r/state $r/microvolts $r/min_microvolts $r/max_microvolts 2>/dev/null; done'
run rpmh 'find /sys/kernel/debug -name "*rpmh*" -o -name "*cmd-db*" | head -20'
# The PMIC the port drives: arbiter map, owner bits, and each block's debugfs.
run spmi 'find /sys/kernel/debug/spmi* -maxdepth 2 2>/dev/null | head -40'
run haptics 'dmesg | grep -i -e hap -e vibr; find /sys/kernel/debug -iname "*hap*"; find /sys/class -iname "*hap*" -o -iname "*leds*" | head'
run thermal 'for z in /sys/class/thermal/thermal_zone*; do echo "== $z $(cat $z/type 2>/dev/null) $(cat $z/temp 2>/dev/null)"; done'
run tsens 'find /sys/kernel/debug -iname "*tsens*" -o -iname "*thermal*" | head -20'
# Storage: the gear, the clocks and the regulator this port has to match.
run ufs 'find /sys/kernel/debug -iname "*ufs*" | head; for h in /sys/class/scsi_host/*; do echo "== $h"; cat $h/../../ufs*/device_descriptor/* 2>/dev/null | head -20; done'
run ufsclk 'dmesg | grep -i -e ufshcd -e ufs_clk -e "gear"'
# Display: timings and the panel's own numbers.
run drm 'cat /sys/class/drm/card0-DSI-1/modes /sys/class/drm/card0-DSI-1/status 2>/dev/null; find /sys/kernel/debug -iname "*dsi*" | head'
run panel 'dmesg | grep -i -e panel -e dsi -e backlight | head -40'
# The rest of the board: inputs, i2c, power, ADC, GPU, soundwire (the haptics rail).
run input 'cat /proc/bus/input/devices'
run i2c 'for d in /sys/bus/i2c/devices/*; do echo "$d $(cat $d/name 2>/dev/null)"; done'
run power 'for p in /sys/class/power_supply/*; do echo "== $p"; cat $p/uevent 2>/dev/null; done'
run iio 'for d in /sys/bus/iio/devices/*; do echo "$d $(cat $d/name 2>/dev/null)"; done'
run gpu 'cat /sys/class/kgsl/kgsl-3d0/gpuclk /sys/class/kgsl/kgsl-3d0/max_gpuclk /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq 2>/dev/null'
run swr 'dmesg | grep -i -e swr -e soundwire -e "hap-swr"; find /sys/bus -iname "*swr*" -o -iname "*soundwire*" | head'
run modules 'cat /proc/modules'
# The device tree the vendor kernel actually booted with.
run fdt 'find /sys/firmware/devicetree/base -maxdepth 1 | head -40'

echo "---"
echo "dump in $OUT (not in git). Grep it; a value only matters once it is a"
echo "constant in tools/boards.py or shim/board.h, or a line in NOTES.md."
