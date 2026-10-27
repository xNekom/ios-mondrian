#!/bin/sh
# Capture, in one Android boot, everything this port needs from the working
# system: the touch driver's own view, the PMIC rails and their consumers, the
# pin mux, clocks, interconnect votes, the input devices (buttons, touch),
# battery, display/GPU and the storage and connectivity state.
#
#   tools/android-capture.sh [OUT.tar]      (adb root is required)
#
# The point is one session instead of many: the device is a test unit and
# every Android flash costs the iOS root in userdata. Run the script, keep the
# tarball, and answer later questions from it instead of booting Android again.

set -eu

OUT=${1:-android-capture.tar}
TMP=/data/local/tmp/capture
ADB=${ADB:-adb}

$ADB root >/dev/null 2>&1 || true
sleep 2
$ADB wait-for-device

$ADB shell "rm -rf $TMP; mkdir -p $TMP/regmap $TMP/pinctrl $TMP/regulator $TMP/power_supply $TMP/input $TMP/clk"

# Kernel and firmware description.
$ADB shell 'dmesg' > "$TMP/dmesg.txt" 2>/dev/null || true
$ADB shell 'cat /proc/config.gz | gzip -dc' > "$TMP/kernel-config.txt" 2>/dev/null || true
$ADB shell 'cat /proc/cmdline' > "$TMP/cmdline.txt" 2>/dev/null || true
$ADB shell 'cat /proc/interrupts' > "$TMP/interrupts.txt" 2>/dev/null || true
$ADB shell 'cat /proc/iomem' > "$TMP/iomem.txt" 2>/dev/null || true
$ADB shell 'cat /proc/modules' > "$TMP/modules.txt" 2>/dev/null || true
$ADB shell 'tar -cf - /proc/device-tree 2>/dev/null' > "$TMP/device-tree.tar" 2>/dev/null || true
$ADB shell 'cat /sys/firmware/fdt' > "$TMP/fdt.dtb" 2>/dev/null || true

# Regulators: the whole table with consumers and modes is the fastest way to
# answer "who powers what and is it really on".
$ADB shell 'cat /sys/kernel/debug/regulator/regulator_summary' > "$TMP/regulator/regulator_summary.txt" 2>/dev/null || true
$ADB shell 'for r in /sys/class/regulator/*; do echo "== $r $(cat $r/name 2>/dev/null)"; cat $r/state $r/microvolts $r/opmode $r/num_users 2>/dev/null; done' > "$TMP/regulator/class.txt" 2>/dev/null || true

# PMIC register maps (SPMI): LDO enables, GPIOs, key sense, charger.
$ADB shell 'for d in /sys/kernel/debug/regmap/*; do n=$(basename $d); test -r $d/registers || continue; echo "== $n"; cat $d/registers; done' > "$TMP/regmap/all.txt" 2>/dev/null || true
$ADB shell 'ls /sys/bus/spmi/devices' > "$TMP/regmap/spmi-devices.txt" 2>/dev/null || true

# Pin mux and pad configuration for every controller.
$ADB shell 'for d in /sys/kernel/debug/pinctrl/*; do echo "== $d"; cat $d/pinmux-pins 2>/dev/null; cat $d/pinconf-pins 2>/dev/null; done' > "$TMP/pinctrl/all.txt" 2>/dev/null || true

# Clocks and bus votes: the port has to reproduce these to talk to any block.
$ADB shell 'cat /sys/kernel/debug/clk/clk_summary' > "$TMP/clk/clk_summary.txt" 2>/dev/null || true
$ADB shell 'cat /sys/kernel/debug/interconnect/interconnect_summary' > "$TMP/interconnect.txt" 2>/dev/null || true
$ADB shell 'cat /sys/kernel/debug/pm_genpd/pm_genpd_summary' > "$TMP/genpd.txt" 2>/dev/null || true

# Touch and buttons, as the working driver sees them.
$ADB shell 'cat /proc/bus/input/devices' > "$TMP/input/devices.txt" 2>/dev/null || true
$ADB shell 'getevent -lp' > "$TMP/input/getevent.txt" 2>/dev/null || true
$ADB shell 'ls -l /sys/class/touch /sys/class/input 2>/dev/null' > "$TMP/input/sysfs.txt" 2>/dev/null || true
$ADB shell 'find /sys -maxdepth 6 -iname "*goodix*" -o -iname "*gtx8*" 2>/dev/null' > "$TMP/input/goodix-nodes.txt" 2>/dev/null || true
$ADB shell 'dmesg | grep -iE "goodix|gtx8|touch|spi_geni|spi-geni"' > "$TMP/input/touch-dmesg.txt" 2>/dev/null || true

# Battery, charger and the ADSP link the battery data comes through.
$ADB shell 'for p in /sys/class/power_supply/*; do echo "== $p"; for f in $p/*; do test -r $f && echo "$(basename $f)=$(cat $f 2>/dev/null)"; done; done' > "$TMP/power_supply/all.txt" 2>/dev/null || true
$ADB shell 'cat /sys/kernel/debug/pmic_glink/* 2>/dev/null' > "$TMP/pmic_glink.txt" 2>/dev/null || true

# Display, GPU and storage.
$ADB shell 'cat /sys/kernel/debug/dri/0/state 2>/dev/null | head -200' > "$TMP/display-drm.txt" 2>/dev/null || true
$ADB shell 'for f in /sys/class/backlight/*/brightness /sys/class/backlight/*/max_brightness; do echo "$f=$(cat $f 2>/dev/null)"; done' > "$TMP/backlight.txt" 2>/dev/null || true
$ADB shell 'ls /sys/class/kgsl/kgsl-3d0/ 2>/dev/null; cat /sys/class/kgsl/kgsl-3d0/gpu_model /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq 2>/dev/null' > "$TMP/gpu.txt" 2>/dev/null || true
$ADB shell 'cat /sys/class/scsi_host/*/../../*/ufs* 2>/dev/null | head -100' > "$TMP/ufs.txt" 2>/dev/null || true

# Connectivity.
$ADB shell 'dmesg | grep -iE "cnss|wlan|wifi|bluetooth|qca" | head -300' > "$TMP/connectivity-dmesg.txt" 2>/dev/null || true
$ADB shell 'ls /sys/class/udc 2>/dev/null; cat /sys/class/udc/*/state 2>/dev/null' > "$TMP/usb.txt" 2>/dev/null || true

# Android's own view, when the system booted.
$ADB shell 'logcat -d -b all' > "$TMP/logcat.txt" 2>/dev/null || true

$ADB shell "cd /data/local/tmp && tar -cf capture.tar capture" 2>/dev/null
$ADB pull /data/local/tmp/capture.tar "$OUT"
echo "captured to $OUT"
