#!/bin/bash
# Deliver the picture bridge and prove it on Settings' Airplane Mode switch.
#
# Run this on a phone that is already booted on the 0402 kernel (tools/wsl/
# cycle.sh --no-build boots one). It writes the two dylibs to /private/var/vm,
# resprings SpringBoard so the hook is the new copy, opens Settings through
# /private/var/vm/mondrian-open (no synthetic touch: the home screen's icon
# view ignores it), and leaves out/switch-settings.png and out/switch-ring.txt.
#
#   tools/wsl/verify-switch.sh
#
# The evidence in the ring:
#   MONDRIAN HOOK: /Applications/Preferences.app/Preferences gets the picture bridge
#   MONDRIAN BRIDGE[<pid>]: 129x129 as surface <id>      (from Preferences)
#   no `MondrianGPU: gem_new ... refused` after the boot's churn
set -u
cd "$(dirname "$0")/../.." || exit 1
IFACE=${IFACE:-enx02005e77ee01}
RING="python3 tools/usb-ring.py"

attach() {
	local b i

	# The bus id moves with the port and changes with the mode: look it up by
	# USB id (1209:0001 is iOS; fastboot is 18d1:d00d and has no netdev).
	b=$(usbipd.exe list 2>/dev/null | grep -a '1209:0001' | awk '{print $1}' | head -1)
	[ -n "${BUSID:-}" ] && b=$BUSID
	[ -n "$b" ] || return 1
	usbipd.exe attach --wsl --busid "$b" > /dev/null 2>&1
	for i in $(seq 1 15); do
		[ -e "/sys/class/net/$IFACE" ] && break
		sleep 1
	done
	[ -e "/sys/class/net/$IFACE" ] || return 1
	ip link set "$IFACE" up 2>/dev/null
	ip addr add 192.168.7.1/24 dev "$IFACE" 2>/dev/null
}

attach || {
	echo "== the phone is not in iOS (no 1209:0001 netdev); boot it first" >&2
	exit 1
}

# The kernel refuses to inject a dylib that is not there, and the two copies
# on the phone are the boot's (glblob=1 writes the hook at mount). Overwrite
# them with the build under test: wfile is the only road that changes a
# root-owned file on this root.
$RING wfile /private/var/vm/mondrian-layer-bridge.dylib \
	out/gpu/mondrian-layer-bridge.dylib || exit 1
$RING wfile /private/var/vm/mondrian-ui-hook.dylib \
	out/gpu/mondrian-ui-hook.dylib || exit 1

# The hook is read at exec, so SpringBoard has to be exec'd again. The bridge
# is read when Settings launches, which happens after this.
$RING respring
$RING wait 25

# Every write of the file is a request (the thread compares contents and
# mtime). A nonce first, then the bundle id, so a repeated write still moves
# the contents even if HFS keeps the timestamp.
printf 'none\n' > out/switch-open.txt
printf 'com.apple.Preferences\n' > out/switch-open.txt
$RING wfile /private/var/vm/mondrian-open out/switch-open.txt || exit 1
$RING wait 10

$RING screen out/switch-settings.png || exit 1
$RING dump out/switch-ring.txt || exit 1

echo "== kernel"
grep -a -m1 'Darwin Kernel Version' out/switch-ring.txt || true
echo "== app injection"
grep -a 'MONDRIAN HOOK: .*gets the picture bridge' out/switch-ring.txt | tail -4 || true
echo "== bridge conversions from Settings"
grep -a 'MONDRIAN BRIDGE' out/switch-ring.txt | tail -8 || true
echo "== read-back answers (UIKit saw the picture, not the surface)"
grep -a 'contents read back' out/switch-ring.txt | tail -6 || true
echo "== pictures read without the surface lock (must not block a commit)"
grep -a 'picture read without the lock' out/switch-ring.txt | head -4 || true
echo "== surfaces in contents that are not the bridge's (must be empty)"
grep -a 'is not a 32-bit picture' out/switch-ring.txt | tail -4 || true
echo "== assertions and SpringBoard crashes (both must be empty)"
grep -a 'Assertion failure in' out/switch-ring.txt | tail -2 || true
grep -a 'CRASH SpringBoard' out/switch-ring.txt | tail -2 || true
echo "== the knob's zero-filled CA surface (must be gone)"
grep -a 'MONDRIAN SURF: backboardd create' out/switch-ring.txt |
    grep -a ' 129x129 ' | tail -2 || true
echo "== refusals since boot"
grep -a -c 'gem_new .* refused' out/switch-ring.txt || true
echo "== panel: out/switch-settings.png"
