#!/bin/bash
# One GPU submission experiment per phone boot.
#
#   tools/wsl/gpu-probe.sh "gpupm4=160"     # extra boot arguments
#
# Flashes the image to boot_b (a volatile `fastboot boot` of this 8 MB image is
# not reliable: most boots never run the shim at all, while the same file
# flashed does), reboots, waits for the kernel to reset to fastboot, flashes the
# recovery back, and pulls the console ring. boot_b holds the recovery on this
# phone, so it is dumped first and restored afterwards.
#
# Extra arguments REPLACE the board's of the same name (the kernel takes the
# first occurrence).
#
# Arguments the user client understands (bsd/dev/mondrian_gpu.c):
#   gpupm4=N      truncate every submitted stream to N dwords (bisection)
#   gpunoblit=1   rewrite CP_BLIT to CP_NOP
#   gpunop=HEX    rewrite one opcode to CP_NOP
#   gpucp=0 gpusubmit=0 gpu=0   turn the CP path off
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
extra=${1:-}
label=$(echo "${extra:-plain}" | tr ' =' '__')
ring=/root/rings/probe-$label.txt
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
FASTBOOT=${FASTBOOT:-/mnt/c/platform-tools/fastboot.exe}
recovery=${RECOVERY_IMG:-backup/boot_b-as-found.img}
tries=${TRIES:-2}

[ -f "$recovery" ] || { echo "error: no recovery dump at $recovery"; exit 1; }

cmdline=$(python3 - "$extra" <<'PY'
import sys
sys.path.insert(0, 'tools')
import boards
line = boards.get_board('mondrian').cmdline.split()
drop = {a.split('=')[0] for a in sys.argv[1].split()}
line = [a for a in line if a.split('=')[0] not in drop]
print(' '.join(line + sys.argv[1].split()))
PY
) || exit 1
echo "== cmdline: $cmdline"

python3 tools/mkpayload.py xnu/out/kernel.development.mondrian \
	shim/out/mondrian.adt shim/out/payload.bin --board mondrian \
	--cmdline "$cmdline" >/dev/null || exit 1
BOARD=mondrian DTB=dtb/mondrian-live.dtb EXTRA_CFLAGS=-DSHIM_NO_UFS \
	shim/build.sh shim/out/payload.bin >/dev/null 2>&1 || exit 1
echo "== image $(stat -c %s shim/out/shim-boot.img) bytes"

state() {
	if "$FASTBOOT" devices 2>/dev/null | grep -q .; then echo fastboot
	elif [ "$("$ADB" get-state 2>/dev/null)" = recovery ]; then echo recovery
	else echo running; fi
}
wait_state() {  # wait_state TARGET SECONDS
	local want=$1 left=$2
	while [ "$left" -gt 0 ]; do
		[ "$(state)" = "$want" ] && return 0
		sleep 5
		left=$((left - 5))
	done
	return 1
}
ring_header() { sed -n '1p' "$1" 2>/dev/null; }

# the phone has to be in fastboot to flash
if [ "$(state)" != fastboot ]; then
	wait_state running 600 && wait_state fastboot 120
	[ "$(state)" = recovery ] && { "$ADB" reboot bootloader >/dev/null 2>&1; wait_state fastboot 120; }
fi
[ "$(state)" = fastboot ] || { echo "error: phone not in fastboot"; exit 1; }

ADB=$ADB bash tools/wsl/pull-ring.sh /root/rings/probe-before.txt >/dev/null 2>&1
before=$(ring_header /root/rings/probe-before.txt)
echo "== ring before: $before"

for try in $(seq 1 "$tries"); do
	echo "== boot $try: flash + reboot"
	"$FASTBOOT" flash boot_b shim/out/shim-boot.img >/dev/null 2>&1 || { echo "error: flash failed"; exit 1; }
	"$FASTBOOT" reboot >/dev/null 2>&1
	sleep 30
	waited=30
	while [ "$waited" -lt 600 ]; do
		[ "$(state)" = fastboot ] && break
		sleep 10
		waited=$((waited + 10))
	done
	echo "== back in fastboot after ${waited}s"
	"$FASTBOOT" flash boot_b "$recovery" >/dev/null 2>&1
	"$FASTBOOT" reboot recovery >/dev/null 2>&1
	wait_state recovery 200 || { echo "  (no recovery; retrying)"; continue; }
	ADB=$ADB bash tools/wsl/pull-ring.sh "$ring" >/dev/null 2>&1
	after=$(ring_header "$ring")
	echo "  ring now: $after"
	if [ "$after" = "$before" ]; then
		echo "  this boot did not arm the ring"
		"$ADB" reboot bootloader >/dev/null 2>&1
		wait_state fastboot 120 || exit 1
		continue
	fi
	echo "== what the user client did"
	grep -a 'uc big\|uc fence\|stopped at' "$ring" | tail -10
	echo "== frames"
	grep -a 'drawn in place' "$ring" | tail -3
	echo "== fps"
	grep -a 'MONDRIAN FB: fps' "$ring" | sort -u | tail -3
	echo "ring: $ring"
	exit 0
done
echo "error: $tries boots without a ring"
exit 1
