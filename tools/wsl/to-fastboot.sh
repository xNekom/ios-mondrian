#!/bin/bash
# Get the phone into fastboot from whatever it is running.
#
#   tools/wsl/to-fastboot.sh
#   FASTBOOT_SERIAL=7e63c267 tools/wsl/to-fastboot.sh  # pin the phone
#
# usbipd's binding is tied to the USB device, and the phone re-enumerates both
# when it leaves iOS and when the bootloader takes over, so the attach has to be
# repeated inside the wait instead of once before it. Asking "why is fastboot
# not there" cost a whole dump attempt.
#
# The bus id is not a constant either: the phone moves ports, and a stale one
# leaves every attach failing while `fastboot devices` (host side, no usbipd)
# still answers, which reads like a phone that never got to the bootloader. It
# is looked up by USB id instead, every time, because the id changes with the
# mode (1209:0001 running, 18d1:d00d in fastboot).
set -u
cd "$(dirname "$0")/../.." || exit 1
FB_BIN=${FB:-/mnt/c/platform-tools/fastboot.exe}
FB=("$FB_BIN")
if [ -n "${FASTBOOT_SERIAL:-}" ]; then
	FB+=(-s "$FASTBOOT_SERIAL")
fi
IFACE=${IFACE:-enx02005e77ee01}

busid() {
	if [ -n "${BUSID:-}" ]; then
		echo "$BUSID"
		return
	fi
	usbipd.exe list 2>/dev/null |
		grep -aE '1209:0001|18d1:d00d' | awk '{print $1}' | head -1
}

try_attach() {
	local b i

	b=$(busid)
	[ -n "$b" ] || return 1
	usbipd.exe attach --wsl --busid "$b" > /dev/null 2>&1
	# usbipd returns before cdc_ether binds and the netdev appears, so wait
	# for the interface instead of a fixed sleep.
	for i in $(seq 1 15); do
		[ -e "/sys/class/net/$IFACE" ] && break
		sleep 1
	done
}

"${FB[@]}" devices 2>/dev/null | grep -q fastboot && { echo "already in fastboot"; exit 0; }

try_attach
if adb devices 2>/dev/null | grep -q -w device; then
	echo "== recovery: adb reboot bootloader"
	adb reboot bootloader > /dev/null 2>&1
else
	echo "== asking the running kernel for fastboot"
	ip link set "$IFACE" up 2>/dev/null
	ip addr add 192.168.7.1/24 dev "$IFACE" 2>/dev/null
	timeout 25 python3 tools/usb-ring.py reboot > /dev/null 2>&1
fi

# The phone lands in fastboot as 18d1:d00d, and `fastboot devices` only sees it
# while usbipd is NOT holding the device: the wait has to look at usbipd's list
# and hand the device back to Windows, or every check runs against a fastboot
# that is attached to WSL and answers nothing. Measured 2026-11-19: the phone
# was in fastboot with the id visible in `usbipd list` while this script spent
# 160 s asking a Windows fastboot that could not see it.
for i in $(seq 1 40); do
	sleep 4
	b=$(usbipd.exe list 2>/dev/null | grep -a '18d1:d00d' | awk '{print $1}' | head -1)
	if [ -n "$b" ]; then
		usbipd.exe detach --busid "$b" > /dev/null 2>&1
		sleep 1
	fi
	"${FB[@]}" devices 2>/dev/null | grep -q fastboot && { echo "fastboot after $((i * 4)) s"; exit 0; }
	try_attach
	"${FB[@]}" devices 2>/dev/null | grep -q fastboot && { echo "fastboot after $((i * 4)) s"; exit 0; }
done
echo "no fastboot: power + volume down" >&2
exit 1
