#!/bin/bash
# One GPU submission experiment per phone boot, unattended.
#
#   tools/wsl/gpu-probe.sh "gpudstate=1"
#
# Works from whatever state the phone is in: it detects fastboot or recovery,
# moves the phone to fastboot if it is not there, builds the image with the
# extra boot arguments (which REPLACE the board's of the same name), flashes it
# to boot_b, boots it, waits for the kernel to reset to fastboot, flashes the
# recovery dump back, boots recovery, pulls the console ring and reports what
# the user client said about its submissions and the frames.
#
# boot_b holds OrangeFox on this phone (README.md), so the recovery image is
# dumped once and restored after every experiment.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
extra=${1:-}
label=$(echo "${extra:-plain}" | tr ' =' '__')
ring=/root/rings/probe-$label.txt
before_ring=/root/rings/probe-before.txt
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
FASTBOOT=${FASTBOOT:-/mnt/c/platform-tools/fastboot.exe}
recovery=${RECOVERY_IMG:-backup/boot_b-as-found.img}
tries=${TRIES:-2}
log=/root/rings/probe-$label.log
exec > >(tee -a "$log") 2>&1

say() { echo "== $*"; }
[ -f "$recovery" ] || { say "error: no recovery dump at $recovery"; exit 1; }

state() {
	if "$FASTBOOT" devices 2>/dev/null | grep -q .; then echo fastboot
	elif "$ADB" get-state 2>/dev/null | grep -q recovery; then echo recovery
	elif "$ADB" get-state 2>/dev/null | grep -q device; then echo device
	else echo none; fi
}

# up to $1 seconds for the phone to reach $2 ("fastboot" or "recovery")
wait_for() {
	local want=$1 left=${2:-300}
	while [ "$left" -gt 0 ]; do
		[ "$(state)" = "$want" ] && return 0
		sleep 3
		left=$((left - 3))
	done
	return 1
}

ensure_fastboot() {
	if [ "$(state)" = fastboot ]; then return 0; fi
	say "phone is in $(state); moving it to fastboot"
	for i in $(seq 1 90); do
		case "$(state)" in
		fastboot) return 0 ;;
		recovery|device) "$ADB" reboot bootloader >/dev/null 2>&1; sleep 6 ;;
		*) sleep 3 ;;	# a boot is running, or the phone is off
		esac
	done
	return 1
}

ring_header() { sed -n '1p' "$1" 2>/dev/null; }

# ---------------------------------------------------------------- the image
cmdline=$(python3 - "$extra" <<'PY'
import sys
sys.path.insert(0, 'tools')
import boards
line = boards.get_board('mondrian').cmdline.split()
drop = {a.split('=')[0] for a in sys.argv[1].split()}
line = [a for a in line if a.split('=')[0] not in drop]
# Every experiment has to end by itself: a wedged GPU bring-up leaves the
# kernel alive but going nowhere, and the reset thread armed at mountroot is
# what brings the phone back to fastboot (0127/0174).
line.append('mondrianreset=90')
print(' '.join(line + sys.argv[1].split()))
PY
) || exit 1
say "cmdline: $cmdline"
python3 tools/mkpayload.py xnu/out/kernel.development.mondrian \
	shim/out/mondrian.adt shim/out/payload.bin --board mondrian \
	--cmdline "$cmdline" >/dev/null || exit 1
BOARD=mondrian DTB=dtb/mondrian-live.dtb EXTRA_CFLAGS=-DSHIM_NO_UFS \
	shim/build.sh shim/out/payload.bin >/dev/null 2>&1 || exit 1
say "image $(stat -c %s shim/out/shim-boot.img) bytes"

# ------------------------------------------------------------- the experiment
ensure_fastboot || { say "error: cannot reach fastboot"; exit 1; }
"$ADB" 2>/dev/null >/dev/null || true
if [ "$(ring_header "$before_ring")" ] && [ "$(state)" = fastboot ]; then :; fi
ADB=$ADB bash tools/wsl/pull-ring.sh "$before_ring" >/dev/null 2>&1 || true
before=$(ring_header "$before_ring")
say "ring before: $before"

for try in $(seq 1 "$tries"); do
	ensure_fastboot || { say "error: lost fastboot"; exit 1; }
	say "boot $try: flash boot_b and reboot"
	"$FASTBOOT" flash boot_b shim/out/shim-boot.img >/dev/null 2>&1 || { say "flash failed"; continue; }
	"$FASTBOOT" reboot >/dev/null 2>&1
	# the kernel runs, then 0127 resets it to fastboot
	waited=0
	while [ "$waited" -lt 600 ]; do
		sleep 10
		waited=$((waited + 10))
		[ "$(state)" = fastboot ] && break
	done
	say "back in fastboot after ${waited}s"
	"$FASTBOOT" flash boot_b "$recovery" >/dev/null 2>&1
	"$FASTBOOT" reboot recovery >/dev/null 2>&1
	if ! wait_for recovery 240; then say "no recovery; retrying"; continue; fi
	ADB=$ADB bash tools/wsl/pull-ring.sh "$ring" >/dev/null 2>&1
	after=$(ring_header "$ring")
	say "ring now: $after"
	if [ "$after" = "$before" ]; then
		say "this boot did not arm the ring"
		before=$after
		continue
	fi
	say "user client"
	grep -a 'uc big\|stopped at\|uc sqe' "$ring" | tail -8
	say "frames"
	grep -a 'drawn in place' "$ring" | tail -2
	say "fps"
	grep -a 'MONDRIAN FB: fps' "$ring" | sort -u | tail -3
	say "ring: $ring"
	exit 0
done
say "error: $tries boots without a ring"
exit 1
