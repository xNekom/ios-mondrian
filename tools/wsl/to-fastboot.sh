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
#
# A reset the kernel asks for can stall on a step (0453). The phone then still
# answers a ping and keeps logging, so "no fastboot" is not "dead": the loop
# reads the live console first -- the last MONDRIAN REBOOT line names the step
# -- and then asks for `hardreset`, which is PSCI alone and cannot reach the
# stalled step. Only when that fails too is a key press the answer.
set -u
cd "$(dirname "$0")/../.." || exit 1
FB=${FB:-/mnt/c/platform-tools/fastboot.exe}
BUSID=${BUSID:-}

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
	# usbipd returns before cdc_ether binds and the netdev appears; attach.sh
	# waits for the driver and sets 192.168.7.1, so callers that need the ring
	# use it instead of this.
}

ring_command() {
	# attach.sh, not try_attach: the ring needs the cdc_ether netdev and the
	# 192.168.7.1 address, and it waits for both.
	bash tools/wsl/attach.sh > /dev/null 2>&1 || return 1
	timeout 25 python3 tools/usb-ring.py "$1" > /dev/null 2>&1
}

wait_fastboot() {
	local rounds=${1:-40} i b

	for i in $(seq 1 "$rounds"); do
		sleep 4
		b=$(usbipd.exe list 2>/dev/null | grep -a '18d1:d00d' | awk '{print $1}' | head -1)
		if [ -n "$b" ]; then
			usbipd.exe detach --busid "$b" > /dev/null 2>&1
			sleep 1
		fi
		"$FB" devices 2>/dev/null | grep -q fastboot && { echo "fastboot after $((i * 4)) s"; return 0; }
		try_attach
		"$FB" devices 2>/dev/null | grep -q fastboot && { echo "fastboot after $((i * 4)) s"; return 0; }
	done
	return 1
}

"$FB" devices 2>/dev/null | grep -q fastboot && { echo "already in fastboot"; exit 0; }

try_attach
if adb devices 2>/dev/null | grep -q -w device; then
	echo "== recovery: adb reboot bootloader"
	adb reboot bootloader > /dev/null 2>&1
else
	echo "== asking the running kernel for fastboot"
	ring_command reboot || true
fi

wait_fastboot 15 && exit 0

# The reset did not arrive. The kernel is probably still up with its reset
# thread stuck: read the step it stopped at from the live console, then try
# the bare PSCI reset.
echo "== no fastboot; reading the live console"
bash tools/wsl/attach.sh > /dev/null 2>&1
python3 tools/wsl/log-listen.py 12 /root/reset-hang.log || true
echo "== hard reset"
ring_command hardreset || true
wait_fastboot 15 && exit 0

echo "no fastboot: power + volume down" >&2
exit 1
