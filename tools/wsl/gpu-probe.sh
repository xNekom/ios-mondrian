#!/bin/bash
# One GPU submission experiment per phone boot.
#
#   tools/wsl/gpu-probe.sh "gpunoblit=1"           # extra boot arguments
#
# Builds a payload whose cmdline is the board's plus the arguments given,
# wraps it in a boot image, boots it, waits for the phone to come back, pulls
# the console ring and prints what the user client said about its submissions.
# The root image is not touched, so no dump/fsck/install cycle is needed.
#
# Some boots die before the kernel arms the ring (a few per ten, cause unknown:
# the panel shows the shim's dark clear). The ring's header (total bytes, flush
# count) tells a real run from a dead one, so a boot that did not write the ring
# is retried instead of being reported as a result.
#
# Boot arguments the user client understands (bsd/dev/mondrian_gpu.c):
#   gpupm4=N      truncate every submitted stream to N dwords (bisection)
#   gpunoblit=1   rewrite CP_BLIT to CP_NOP
#   gpunop=HEX    rewrite one opcode to CP_NOP
#   gpuqueue=N    submit the reference stream N times
#   gpudrawstate  keep CP_SET_DRAW_STATE in the stream
#   gpucp=0 gpusubmit=0 gpu=0   turn the CP path off
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
extra=${1:-}
label=$(echo "${extra:-plain}" | tr ' =' '__')
ring=/root/rings/probe-$label.txt
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
FASTBOOT=${FASTBOOT:-/mnt/c/platform-tools/fastboot.exe}
tries=${TRIES:-2}

cmdline=$(python3 - "$extra" <<'PY'
import sys
sys.path.insert(0, 'tools')
import boards
line = boards.get_board('mondrian').cmdline
extra = sys.argv[1].strip()
print((line + ' ' + extra).strip() if extra else line)
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
header() {  # header FILE -> the ring's "# version ..." line
	sed -n '1p' "$1" 2>/dev/null
}
fetch_ring() {  # fetch_ring FILE
	ADB=$ADB bash tools/wsl/pull-ring.sh "$1" >/dev/null 2>&1
}

# let any running boot finish, then sit in fastboot
wait_state fastboot 0 || wait_state recovery 600
case "$(state)" in
recovery) "$ADB" reboot bootloader >/dev/null 2>&1; wait_state fastboot 120 || { echo "error: no fastboot"; exit 1; } ;;
fastboot) ;;
*) echo "error: phone busy ($(state))"; exit 1 ;;
esac

before=$(fetch_ring /root/rings/probe-before.txt; header /root/rings/probe-before.txt)
echo "== ring before: $before"

for try in $(seq 1 "$tries"); do
	echo "== boot $try"
	"$FASTBOOT" boot shim/out/shim-boot.img >/dev/null 2>&1 || { echo "error: boot failed"; exit 1; }
	waited=0
	while [ "$waited" -lt 900 ]; do
		[ "$(state)" != running ] && break
		sleep 10
		waited=$((waited + 10))
	done
	echo "== phone back after ${waited}s ($(state))"
	[ "$(state)" = fastboot ] && { "$FASTBOOT" reboot recovery >/dev/null 2>&1; }
	wait_state recovery 200 || { echo "  (no recovery; retrying)"; continue; }
	fetch_ring "$ring"
	after=$(header "$ring")
	echo "  ring now: $after"
	if [ "$after" = "$before" ]; then
		echo "  this boot did not arm the ring"
		"$ADB" reboot bootloader >/dev/null 2>&1
		wait_state fastboot 120 || exit 1
		continue
	fi
	echo "== what the user client did"
	grep -a 'uc sqe\|stopped at\|uc big\|uc fence\|cp start without' "$ring" | tail -14
	echo "== fps"
	grep -a 'MONDRIAN FB: fps' "$ring" | tail -2
	echo "ring: $ring"
	exit 0
done
echo "error: $tries boots without a ring"
exit 1
