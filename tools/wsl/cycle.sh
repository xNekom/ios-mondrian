#!/bin/bash
# One experiment per boot: build the kernel, build the image, boot it from RAM,
# prove which kernel answered, and run the ring commands you asked for.
#
#   tools/wsl/cycle.sh haps "vib 150 64"
#   tools/wsl/cycle.sh --no-build thermal
#   EXTRA_ARGS=thermalthr=30 tools/wsl/cycle.sh thermal
#
# The exit status is 0 only when the ring's Darwin banner is the kernel that was
# just built. A RAM boot that dies falls back to boot_b and answers with the
# previous kernel; every command then "does not exist" and the answer is not
# about this build at all. That mistake has cost whole afternoons.
#
# Nothing here is piped through head or tail: SIGPIPE killed mkimg.sh once and
# left the old image on disk. For the same reason a caller must not pipe it
# either: a daemon the boot script starts would hold the pipe open after the
# script exits and the call would never return.
#
# A RAM boot after an XNU run can die at the shim handoff and fall back to
# boot_b. Measured 2026-11-19: two attempts died, the third in the same session
# booted the image -- no power cycle. So the boot is retried here, with the slot
# re-activated each time (a failed boot marks it unbootable), instead of the
# caller waiting on a phone that will never answer.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

BUILD=1
if [ "${1:-}" = "--no-build" ]; then
	BUILD=0
	shift
fi
CMDS=()
case "${1:-}" in
@*)
	# "@FILE" reads one command per line. Inline commands need their spaces
	# quoted, and a shell one level up (PowerShell calling wsl) eats those
	# quotes: `hapr 0 0` arrived as a bare `hapr` and the block "did not
	# answer". A file has no quoting to lose.
	while IFS= read -r line; do
		[ -n "$line" ] && CMDS+=("$line")
	done < "${1#@}"
	;;
*)
	# No command at all is a valid run (boot it and read the ring); `set -u`
	# on a bare "$1" made that die with "1: unbound variable".
	CMDS=("$@")
	;;
esac
IFACE=${IFACE:-enx02005e77ee01}
BUSID=${BUSID:-}
FB=${FB:-/mnt/c/platform-tools/fastboot.exe}
K=xnu/out/kernel.development.mondrian
LOG=${LOG:-/root/cycle}

mkdir -p "$LOG" || exit 1

# 1. The kernel.
if [ "$BUILD" = 1 ]; then
	echo "== build"
	bash tools/wsl/build-kernel.sh > "$LOG/build.log" 2>&1
	if [ $? -ne 0 ]; then
		grep -a -n 'error:' "$LOG/build.log" | tail -6
		echo "== build failed: $LOG/build.log"
		exit 1
	fi
fi
[ -f "$K" ] || { echo "no $K"; exit 1; }
WANT=$(grep -a -o -m1 'Darwin Kernel Version[^;]*' "$K" | head -1)
echo "== image"
bash tools/wsl/image.sh || exit 1
# image.sh already recorded and verified; this re-reads the manifest after the
# file has been closed, so a write that lost a race cannot reach `fastboot boot`.
python3 tools/verify-image.py || exit 1

# 2. The phone has to be in fastboot before anything is loaded.
attach() {
	local b i

	# By USB id, not by a fixed port: the phone moves, and a stale bus id
	# leaves every attach failing while `fastboot devices` keeps answering.
	b=$(usbipd.exe list 2>/dev/null | grep -aE '1209:0001|18d1:d00d' |
		awk '{print $1}' | head -1)
	[ -n "${BUSID:-}" ] && b=$BUSID
	[ -n "$b" ] || return 1
	usbipd.exe attach --wsl --busid "$b" > /dev/null 2>&1
	# usbipd returns before cdc_ether binds and the netdev appears: a fixed
	# sleep raced it and the ring looked dead on a phone that was up.
	for i in $(seq 1 15); do
		[ -e "/sys/class/net/$IFACE" ] && break
		sleep 1
	done
	ip link set "$IFACE" up 2>/dev/null
	ip addr add 192.168.7.1/24 dev "$IFACE" 2>/dev/null
}

"$FB" devices 2>/dev/null | grep -q fastboot || {
	echo "== asking the running kernel for fastboot"
	bash tools/wsl/to-fastboot.sh || exit 1
}
"$FB" devices 2>/dev/null | grep -q fastboot || {
	echo "== no fastboot: power + volume down, or check the cable"
	exit 1
}

echo "== fastboot boot"
WIMG=$(wslpath -w "$PWD/shim/out/shim-boot.img")
# The ABL marks the active slot unbootable after a failed boot and then refuses
# every RAM boot with "Failed to load/authenticate boot image: Not Found",
# whatever image is handed to it -- a 4 KB stub is refused the same way, and so
# is an image that booted an hour earlier. Re-activating the slot before the
# boot clears it.
#
# `getvar` on Windows ends its lines with CRLF, so the value arrives as "b\r"
# and `--set-active=b\r` is rejected with "Slot b does not exist"; the mark then
# survives, the next RAM boots die the same way, and each one looks like a kernel
# that crashes. Strip the CR, and say so when the clear fails.
ATTEMPTS=${ATTEMPTS:-3}
BOOTED=0
for attempt in $(seq 1 "$ATTEMPTS"); do
	echo "== boot attempt $attempt of $ATTEMPTS"
	# A RAM boot that dies falls back to boot_b, and that boot leaves fastboot:
	# the next attempt's `getvar` would then block for ever on
	# "< waiting for any device >" (measured: the retry never reached a second
	# `fastboot boot`, and the run was read as a hung boot). Ask the running
	# kernel again instead of waiting on a device that is gone.
	if ! "$FB" devices 2>/dev/null | grep -q fastboot; then
		echo "== fastboot is gone; asking the running kernel again"
		bash tools/wsl/to-fastboot.sh || { sleep 5; continue; }
	fi
	SLOT=$(timeout 30 "$FB" getvar current-slot 2>&1 | tr -d '\r' |
		sed -n 's/^current-slot: *//p' | head -1)
	if [ -n "$SLOT" ]; then
		if timeout 60 "$FB" --set-active="$SLOT" > "$LOG/set-active.log" 2>&1; then
			echo "   slot $SLOT re-activated"
		else
			cat "$LOG/set-active.log"
			echo "== could not re-activate slot $SLOT: every RAM boot will be refused" >&2
			exit 1
		fi
	fi
	timeout 60 "$FB" boot "$WIMG" > "$LOG/fastboot.log" 2>&1
	# "Sending 'boot.img' ... OKAY" is printed even when the boot itself fails,
	# and a check that only looks for OKAY passes on it: the image was never
	# loaded and the phone fell back to boot_b, which then looks like a kernel
	# that crashes.
	if grep -a -q 'FAILED' "$LOG/fastboot.log" ||
	    ! grep -a -q "Booting.*OKAY" "$LOG/fastboot.log"; then
		tail -3 "$LOG/fastboot.log"
		echo "== the bootloader refused the RAM boot (see above)" >&2
		echo "   fall back to: tools/wsl/flash-image.sh   (writes boot_<slot>)" >&2
		exit 1
	fi

	# 3. Wait for the ring, then prove the kernel.
	echo "== waiting for the ring"
	UP=0
	for i in $(seq 1 40); do
		sleep 6
		attach
		if timeout 20 python3 tools/usb-ring.py pos > "$LOG/pos.txt" 2>&1 &&
		    grep -a -qE '^[0-9]+$' "$LOG/pos.txt"; then
			UP=1
			break
		fi
	done
	if [ "$UP" != 1 ]; then
		echo "== the ring never answered on attempt $attempt"
		continue
	fi
	timeout 250 python3 tools/usb-ring.py dump "$LOG/ring.txt" > "$LOG/dump.txt" 2>&1
	GOT=$(grep -a -m1 -o 'Darwin Kernel Version[^;]*' "$LOG/ring.txt")
	echo "   want: ${WANT:-?}"
	echo "   got:  ${GOT:-?}"
	if [ "${WANT:-x}" = "${GOT:-y}" ]; then
		BOOTED=1
		break
	fi
	echo "== attempt $attempt answered with another kernel (ring in $LOG/ring.txt)"
done
if [ "$BOOTED" != 1 ]; then
	echo "== NOT this build after $ATTEMPTS attempts: the RAM boot keeps dying at the" >&2
	echo "   shim handoff and boot_b answers. Retry once more; a cold power cycle" >&2
	echo "   (10 s off, power + volume down) is the fallback." >&2
	exit 2
fi

# 4. The commands.
for c in "${CMDS[@]}"; do
	echo "-- $c"
	# a tree walk can run for minutes; the timeout is a ceiling, not a target
	timeout 600 python3 tools/usb-ring.py $c 2>&1 | tail -4
done

echo "== ring: MONDRIAN lines"
timeout 250 python3 tools/usb-ring.py dump "$LOG/ring.txt" > "$LOG/dump2.txt" 2>&1
grep -a 'MONDRIAN' "$LOG/ring.txt" | tail -20
for c in "${CMDS[@]}"; do
	name=${c%% *}
	echo "-- ring: $name"
	grep -a -i -e "$name" "$LOG/ring.txt" | tail -6
done
echo "== logs in $LOG"
