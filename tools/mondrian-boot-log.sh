#!/bin/bash
# Boot a test image, wait for the automatic reset, and pull the mondrian ring.
#
#   tools/mondrian-boot-log.sh [IMAGE] [--ios IOS.img] [--out FILE] [--reset S]
#
# Build IMAGE with `mondrianreset=<seconds>` (tools/phone-deploy.sh build with
# that in CMDLINE) so the kernel returns to fastboot on its own. The script
# then:
#   1. puts the phone in the bootloader (adb or fastbootd if needed),
#   2. fastboot-boots IMAGE and waits for fastboot to come back,
#   3. boots RECOVERY and pulls the last 1025 blocks of ROOT_PART,
#   4. decodes them with tools/decode-mondrian-log.py,
#   5. with --ios, boots IOS.img so the phone is left in iOS.
#
# Nothing is written to a partition: both boots are volatile. The defaults
# point at the per-user work dir used by the deploy tools; override them with
# WORK, RECOVERY, IOS_IMAGE, SERIAL, ROOT_PART.
set -u
cd "$(dirname "$0")/.."

WORK=${WORK:-${TMPDIR:-/tmp}/opencode}
RECOVERY=${RECOVERY:-$WORK/orangefox-volatile.img}
SERIAL=${SERIAL:-}
ROOT_PART=${ROOT_PART:-userdata}
IOS_IMAGE=${IOS_IMAGE:-}
OUT=${OUT:-mondrian-console.log}
RESET=${RESET:-90}
IMAGE=""

while [ $# -gt 0 ]; do
	case "$1" in
	--ios) IOS_IMAGE=${2:?--ios needs an image}; shift 2 ;;
	--out) OUT=${2:?--out needs a file}; shift 2 ;;
	--reset) RESET=${2:?--reset needs seconds}; shift 2 ;;
	-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) echo "usage: $0 [IMAGE] [--ios IOS.img] [--out FILE] [--reset S]" >&2; exit 2 ;;
	*) IMAGE=$1; shift ;;
	esac
done

command -v fastboot >/dev/null || { echo "falta fastboot" >&2; exit 1; }
command -v adb >/dev/null || { echo "falta adb" >&2; exit 1; }
[ -n "$IMAGE" ] || IMAGE=$(ls -t "$WORK"/boot-*.img 2>/dev/null | head -1)
[ -n "$IMAGE" ] && [ -f "$IMAGE" ] || { echo "no hay imagen; pasa IMAGE" >&2; exit 1; }
[ -f "$RECOVERY" ] || { echo "no hay recovery en $RECOVERY (RECOVERY=...)" >&2; exit 1; }

fb() { if [ -n "$SERIAL" ]; then fastboot -s "$SERIAL" "$@"; else fastboot "$@"; fi; }
fb_dev() { fastboot devices 2>/dev/null | grep -q .; }
adb_dev() { adb devices 2>/dev/null | grep -qE '[[:space:]]device$'; }

# Put the phone in the bootloader whatever it is running now.
if adb_dev; then
	echo "== adb: pidiendo el bootloader"
	adb reboot bootloader >/dev/null 2>&1 || true
	sleep 5
fi
if fb_dev && fb getvar is-userspace 2>&1 | grep -q yes; then
	echo "== fastbootd: volviendo al bootloader"
	fb reboot bootloader >/dev/null 2>&1 || true
	sleep 8
fi
for _ in $(seq 1 30); do fb_dev && break; sleep 2; done
fb_dev || { echo "el movil no esta en fastboot" >&2; exit 1; }
[ -n "$SERIAL" ] || SERIAL=$(fastboot devices | awk 'NR==1{print $1}')

echo "== arrancando $(basename "$IMAGE") (fastboot boot)"
fb boot "$IMAGE" >/dev/null 2>&1 || { echo "fastboot boot fallo" >&2; exit 1; }
# The bootloader stays visible for a moment after fastboot boot returns;
# wait until the image takes the USB away before starting the clock.
gone=0
for _ in $(seq 1 30); do
	if ! fb_dev; then gone=1; break; fi
	sleep 1
done
[ "$gone" = 1 ] || echo "aviso: el bootloader no desaparecio" >&2
start=$(date +%s)
echo "== esperando el reset automatico (max $((RESET + 120))s)"
deadline=$((start + RESET + 120))
while [ "$(date +%s)" -lt "$deadline" ]; do
	if fb_dev; then
		if fb getvar is-userspace 2>&1 | grep -q yes; then
			echo "== fastbootd: volviendo al bootloader"
			fb reboot bootloader >/dev/null 2>&1 || true
			sleep 8
			continue
		fi
		echo "== de vuelta en el bootloader a los $(( $(date +%s) - start ))s"
		break
	fi
	sleep 5
done
fb_dev || { echo "no volvio a fastboot; pasalo a mano" >&2; exit 1; }

echo "== arrancando recovery"
fb boot "$RECOVERY" >/dev/null 2>&1 || { echo "fastboot boot recovery fallo" >&2; exit 1; }
for i in $(seq 1 50); do
	adb shell echo ok 2>/dev/null | grep -q ok && break
	if [ $((i % 5)) -eq 0 ]; then
		adb kill-server 2>/dev/null; adb start-server 2>/dev/null
	fi
	sleep 3
done
adb_dev || { echo "el recovery no responde por adb" >&2; exit 1; }

dev=$(adb shell "for d in /dev/block/by-name/$ROOT_PART /dev/block/bootdevice/by-name/$ROOT_PART; do [ -e \$d ] && readlink -f \$d && break; done" 2>/dev/null | tr -d '\r')
[ -n "$dev" ] || { echo "no encuentro /dev/block/by-name/$ROOT_PART" >&2; exit 1; }
bytes=$(adb shell blockdev --getsize64 "$dev" | tr -d '\r')
skip=$(( bytes / 4096 - 1025 ))
echo "== $dev: $bytes bytes, leyendo los bloques $skip.."
adb exec-out "dd if=$dev bs=4096 skip=$skip count=1025 2>/dev/null" > "$OUT.raw"
python3 tools/decode-mondrian-log.py "$OUT.raw" > "$OUT" 2>/dev/null || true
echo "== $OUT"
head -1 "$OUT" 2>/dev/null
tail -15 "$OUT" 2>/dev/null | cut -c1-160
grep -a -E 'MONDRIAN GPU|MONDRIAN EARLY|panic|MONDRIAN RESET' "$OUT" 2>/dev/null | tail -10 | cut -c1-160

if [ -n "$IOS_IMAGE" ]; then
	[ -f "$IOS_IMAGE" ] || { echo "no hay iOS en $IOS_IMAGE" >&2; exit 1; }
	echo "== volviendo a iOS"
	adb reboot bootloader >/dev/null 2>&1 || true
	for _ in $(seq 1 30); do fb_dev && break; sleep 2; done
	fb boot "$IOS_IMAGE" >/dev/null 2>&1 || { echo "fastboot boot iOS fallo" >&2; exit 1; }
	echo "== iOS arrancado (log en $OUT)"
else
	echo "== el movil queda en recovery; para iOS: pasa --ios IMAGE"
fi
