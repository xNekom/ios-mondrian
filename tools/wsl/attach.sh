#!/bin/bash
# Attach the phone to WSL and give it 192.168.7.1, the ring's address.
#
# Every WSL invocation is a fresh VM (it shuts down between tool calls), so
# usbipd has to attach again and the netdev has to be brought up again before
# the first command is sent; otherwise usb-ring.py dies at bind() with
# "Cannot assign requested address". The bus id moves with the USB port and the
# interface name with the gadget's MAC, so neither is hardcoded: the bus id is
# looked up by USB id and the interface by its driver (cdc_ether).
#
# The phone must already be in fastboot mode or booted with usb=2; this only
# moves an enumerated device into WSL.
set -e
BUSID=${BUSID:-}

if [ -z "$BUSID" ]; then
	BUSID=$(usbipd.exe list 2>/dev/null | grep -aE '1209:0001|18d1:d00d' | awk '{print $1}' | head -1)
fi
if [ -z "$BUSID" ]; then
	echo "attach.sh: no device with USB id 1209:0001 (shim) or 18d1:d00d (fastboot) in usbipd list" >&2
	exit 1
fi

# Not silent: "attach failed: device is not shared" is the answer when the
# device needs `usbipd bind` first, and hiding it made a broken attach look
# like a phone that never enumerated. "Already attached to a client" is the
# normal state after a WSL restart in the same session (the vhci device and its
# netdev outlive the shell), so it is not an error.
if ! out=$(usbipd.exe attach --wsl --busid "$BUSID" 2>&1); then
	if ! printf '%s' "$out" | grep -q 'already attached'; then
		echo "attach.sh: usbipd attach failed for $BUSID:" >&2
		echo "$out" | sed 's/^/  /' >&2
		exit 1
	fi
fi

# usbipd returns before cdc_ether binds and the netdev appears: wait for the
# driver rather than for a name, since the name follows the gadget's MAC.
iface=
for _ in $(seq 1 15); do
	for dir in /sys/class/net/*; do
		[ -e "$dir/device/driver" ] || continue
		[ "$(basename "$(readlink -f "$dir/device/driver")")" = cdc_ether ] || continue
		iface=$(basename "$dir")
		break
	done
	[ -n "$iface" ] && break
	sleep 1
done
if [ -z "$iface" ]; then
	echo "attach.sh: attached $BUSID but no cdc_ether interface appeared; is the phone booted with usb=2?" >&2
	exit 1
fi

ip link set "$iface" up 2>/dev/null || true
ip addr add 192.168.7.1/24 dev "$iface" 2>/dev/null || true
echo "attach.sh: $iface up as 192.168.7.1 (bus id $BUSID)"
