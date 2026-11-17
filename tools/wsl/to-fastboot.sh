#!/bin/bash
# Get the phone into fastboot from whatever it is running.
#
#   tools/wsl/to-fastboot.sh
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
FB=${FB:-/mnt/c/platform-tools/fastboot.exe}
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
	local b

	b=$(busid)
	[ -n "$b" ] || return 1
	usbipd.exe attach --wsl --busid "$b" > /dev/null 2>&1
	sleep 3
}

"$FB" devices 2>/dev/null | grep -q fastboot && { echo "already in fastboot"; exit 0; }

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

for i in $(seq 1 40); do
	sleep 4
	"$FB" devices 2>/dev/null | grep -q fastboot && { echo "fastboot after $((i * 4)) s"; exit 0; }
	try_attach
	"$FB" devices 2>/dev/null | grep -q fastboot && { echo "fastboot after $((i * 4)) s"; exit 0; }
done
echo "no fastboot: power + volume down" >&2
exit 1
