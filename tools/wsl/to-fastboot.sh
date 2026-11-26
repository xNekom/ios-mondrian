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
# A reset the kernel asks for can stall or lose its restart reason, and the
# phone then comes back on the disk slot instead of the bootloader. The live
# console is captured *during* the attempt, not after it: the next kernel
# re-initialises the ring, so the MONDRIAN RESET lines that name the step are
# gone by the time a failure is visible (measured 2026-11-26, a reset that
# landed on boot_b left no trace in the new ring). Only when every host step
# fails is a key press the answer.
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
	# 192.168.7.1 address, and it waits for both. Ask "pos" first and require
	# an answer: a command sent into a channel that is not up is dropped
	# silently, and the tool still prints "reboot sent" (measured 2026-11-26,
	# a reboot that was never sent read exactly like one the kernel ignored).
	bash tools/wsl/attach.sh > /dev/null 2>&1 || { echo "   attach failed"; return 1; }
	timeout 20 python3 tools/usb-ring.py pos > /dev/null 2>&1 || { echo "   ring silent"; return 1; }
	timeout 25 python3 tools/usb-ring.py "$1" > /dev/null 2>&1
}

ring_command_capture() {
	local log=/root/reset-console.log lp

	bash tools/wsl/attach.sh > /dev/null 2>&1 || { echo "   attach failed"; return 1; }
	timeout 20 python3 tools/usb-ring.py pos > /dev/null 2>&1 || { echo "   ring silent"; return 1; }
	rm -f "$log"
	python3 tools/wsl/log-listen.py 25 "$log" > /dev/null 2>&1 &
	lp=$!
	sleep 2
	timeout 25 python3 tools/usb-ring.py "$1" > /dev/null 2>&1
	wait "$lp" 2>/dev/null
	# The reset path prints the step it reached before the last flush.
	if [ -s "$log" ]; then
		grep -a -e 'MONDR USB: reboot' -e 'MONDR USB: hard' \
		    -e 'MONDR USB: bcb' -e 'MONDRIAN REBOOT' -e 'MONDRIAN RESET' \
		    -e 'MONDRIAN HARD RESET' "$log" | tail -8
	fi
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
	wait_fastboot 15 && exit 0
fi

echo "== asking the running kernel for fastboot"
ring_command_capture reboot || true
wait_fastboot 15 && exit 0

# The ring reboot did not arrive. `hardreset` is the same BCB, restart reason
# and PSCI without the HFS sync, and its reason write is bounded, so it cannot
# strand the command port (0457).
echo "== hard reset"
ring_command_capture hardreset || true
wait_fastboot 15 && exit 0

# Last host-side resort: write the boot control block explicitly and reset
# again. ABL reads the restart reason first, the BCB is the second hint.
echo "== bcb bootloader + hard reset"
ring_command_capture "bcb bootloader" || true
ring_command_capture hardreset || true
wait_fastboot 15 && exit 0

echo "no fastboot: power + volume down" >&2
exit 1
