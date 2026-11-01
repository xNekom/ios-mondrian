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
case "$(state)" in
recovery) "$ADB" reboot bootloader >/dev/null 2>&1; sleep 8 ;;
esac
"$FASTBOOT" devices 2>/dev/null | grep -q . || { echo "error: no fastboot"; exit 1; }
echo "== boot"
"$FASTBOOT" boot shim/out/shim-boot.img >/dev/null 2>&1 || { echo "error: boot failed"; exit 1; }

waited=0
while [ "$waited" -lt 900 ]; do
	[ "$(state)" != running ] && break
	sleep 10
	waited=$((waited + 10))
done
echo "== phone back after ${waited}s ($(state))"
[ "$(state)" = fastboot ] && { "$FASTBOOT" reboot recovery >/dev/null 2>&1; sleep 20; }
for i in $(seq 1 40); do [ "$(state)" = recovery ] && break; sleep 5; done
ADB=$ADB bash tools/wsl/pull-ring.sh "$ring" >/dev/null 2>&1 || { echo "error: no ring"; exit 1; }

echo "== what the user client did"
grep -a 'uc sqe\|stopped at\|uc big\|uc fence\|cp start\|service published\|gpu submit' "$ring" | tail -14
echo "== fps"
grep -a 'MONDRIAN FB: fps' "$ring" | tail -2
echo "ring: $ring"
