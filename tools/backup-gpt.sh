#!/bin/sh
# Dump the partition table of the phone's internal UFS before an iteration that
# could write to it. The UFS root driver here only reads blocks and issues
# START STOP UNIT, so today nothing can corrupt the table; this exists for the
# moment writes are enabled (ufsrw=1, a read-write root, the persistent log
# ring), because a bad write to LUN 0 is not recoverable from the phone.
#
#   tools/backup-gpt.sh [-s SERIAL] [OUTDIR]      (default: ~/mondrian-backups)
#
# Two independent records are kept, because they answer different questions:
#
#   partition-table.txt  `fastboot getvar all`: every partition the bootloader
#                        knows, names, sizes and slots. Shows the damage.
#   gpt-primary.bin      LBA 0..33: the protective MBR, the GPT header and the
#   gpt-backup.bin       128 entries. The table itself; restores the damage.
#                        LBA (last-32)..last: the backup copy of the same.
#
# The bins need adb root (TWRP is root by default, Android needs `adb root`).
# If only fastboot is reachable, the script still writes partition-table.txt
# and says what is missing.
#
# Verify a dump by hand with:  sgdisk --verify <(--load-backup) file>
# or simply `grep -c 'EFI PART'`, which must find one header per bin file.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${HOME}/mondrian-backups
SERIAL=

usage() {
	echo "Usage: $(basename "$0") [-s SERIAL] [OUTDIR]"
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case $1 in
	-s) shift; SERIAL=${1:?Error: -s needs a serial}; shift ;;
	-h | --help) usage 0 ;;
	*) OUT=$1; shift ;;
	esac
done

FASTBOOT=fastboot
ADB=adb
if [ -n "$SERIAL" ]; then
	FASTBOOT="fastboot -s $SERIAL"
	ADB="adb -s $SERIAL"
fi

mkdir -p "$OUT"
STAMP=$(date +%Y%m%d-%H%M%S)

# 1. What the bootloader thinks the table is. Reads only.
printf 'fastboot getvar all ... '
if $FASTBOOT getvar all >"$OUT/partition-table-$STAMP.txt" 2>&1; then
	echo "ok ($OUT/partition-table-$STAMP.txt)"
else
	echo "FAILED (is the phone in fastboot mode?)"
	rm -f "$OUT/partition-table-$STAMP.txt"
	exit 1
fi
ln -sf "partition-table-$STAMP.txt" "$OUT/partition-table.txt"

# 2. The raw GPT. Needs a booted system (or recovery) with adb root.
if ! $ADB get-state >/dev/null 2>&1; then
	echo "no adb device: the raw GPT was not read."
	echo "  boot TWRP (fastboot boot <recovery>.img) and run this again,"
	echo "  or accept the bootloader's view above."
	exit 0
fi

DEV=/dev/block/sda
SECTORS=$($ADB shell "blockdev --getsz $DEV 2>/dev/null || cat /sys/class/block/sda/size" | tr -d '\r')
case $SECTORS in
'' | *[!0-9]*) echo "cannot read the sector count of $DEV" >&2; exit 1 ;;
esac
printf 'disk: %s sectors of 512 bytes (%.1f GiB)\n' "$SECTORS" \
	"$(echo "$SECTORS" | awk '{ printf "%.1f", $1 * 512 / 1073741824 }')"

# A 512-byte-sector GPT: LBA 1 header, LBA 2..33 the 128 entries.
PRIMARY="$OUT/gpt-primary-$STAMP.bin"
BACKUP="$OUT/gpt-backup-$STAMP.bin"
BACKUP_FIRST=$((SECTORS - 33))

printf 'primary GPT (LBA 0..33) ... '
if $ADB exec-out "su -c 'dd if=$DEV bs=512 count=34 2>/dev/null' || dd if=$DEV bs=512 count=34 2>/dev/null" \
	>"$PRIMARY" && [ -s "$PRIMARY" ]; then
	echo "ok ($(wc -c <"$PRIMARY" | tr -d ' ') bytes)"
else
	echo "FAILED"; rm -f "$PRIMARY"
fi

printf 'backup GPT (LBA %d..%d) ... ' "$BACKUP_FIRST" "$((SECTORS - 1))"
if $ADB exec-out "su -c 'dd if=$DEV bs=512 skip=$BACKUP_FIRST 2>/dev/null' || dd if=$DEV bs=512 skip=$BACKUP_FIRST 2>/dev/null" \
	>"$BACKUP" && [ -s "$BACKUP" ]; then
	echo "ok ($(wc -c <"$BACKUP" | tr -d ' ') bytes)"
else
	echo "FAILED"; rm -f "$BACKUP"
fi

for f in "$PRIMARY" "$BACKUP"; do
	[ -f "$f" ] || continue
	if grep -qa 'EFI PART' "$f"; then
		printf '%s: EFI PART found, %s\n' "$(basename "$f")" \
			"$(shasum -a 256 "$f" | cut -d' ' -f1)"
	else
		printf '%s: NO EFI PART: this is not a GPT header\n' "$(basename "$f")" >&2
	fi
done

for f in "$PRIMARY" "$BACKUP"; do
	[ -f "$f" ] || continue
	base=$(basename "$f" | sed 's/-[0-9]*-[0-9]*\.bin$//')
	ln -sf "$(basename "$f")" "$OUT/$base.bin"
done
echo "done: $OUT"
