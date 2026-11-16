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
# left the old image on disk.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

BUILD=1
if [ "${1:-}" = "--no-build" ]; then
	BUILD=0
	shift
fi
CMDS=()
if [ "${1#@}" != "${1:-}" ]; then
	# "@FILE" reads one command per line. Inline commands need their spaces
	# quoted, and a shell one level up (PowerShell calling wsl) eats those
	# quotes: `hapr 0 0` arrived as a bare `hapr` and the block "did not
	# answer". A file has no quoting to lose.
	while IFS= read -r line; do
		[ -n "$line" ] && CMDS+=("$line")
	done < "${1#@}"
else
	CMDS=("$@")
fi
IFACE=${IFACE:-enx02005e77ee01}
BUSID=${BUSID:-7-1}
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

# 2. The phone has to be in fastboot before anything is loaded.
attach() {
	usbipd.exe attach --wsl --busid "$BUSID" > /dev/null 2>&1
	sleep 5
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
timeout 60 "$FB" boot "$WIMG" > "$LOG/fastboot.log" 2>&1
grep -a -q OKAY "$LOG/fastboot.log" || { tail -3 "$LOG/fastboot.log"; exit 1; }

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
[ "$UP" = 1 ] || { echo "== the ring never answered"; exit 1; }
timeout 250 python3 tools/usb-ring.py dump "$LOG/ring.txt" > "$LOG/dump.txt" 2>&1
GOT=$(grep -a -m1 -o 'Darwin Kernel Version[^;]*' "$LOG/ring.txt")
echo "   want: ${WANT:-?}"
echo "   got:  ${GOT:-?}"
if [ "${WANT:-x}" != "${GOT:-y}" ]; then
	echo "== NOT this build (the RAM boot died and boot_b answered): ring in $LOG/ring.txt"
	exit 2
fi

# 4. The commands.
for c in "${CMDS[@]}"; do
	echo "-- $c"
	timeout 120 python3 tools/usb-ring.py $c 2>&1 | tail -4
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
