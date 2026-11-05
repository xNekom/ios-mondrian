#!/bin/bash
# Update the iOS root on the phone without rewriting the whole partition.
#
#   tools/wsl/push-root.sh --save-base
#       Dump userdata, repair it with fsck.hfsplus and remember it as the base.
#   tools/wsl/push-root.sh --dylib FILE [--inject FILE] [--mesa DIR]
#                          [--flash] [--dry-run] [--force] [--yes]
#       Copy the base, install the userland into the copy, then send only the
#       changed blocks (tools/wsl/push-blocks.py: a few MB, not 16 GiB).
#       --flash builds the sparse image and rewrites userdata with
#       fastboot -S 64M, for the runs where the diff push cannot be used.
#
# The base has to be what the phone holds *now*: the kernel mounts the root
# read-write (rootrw=1) and writes to it on every boot, so a diff taken from
# an older base lands file data on blocks the volume now uses for metadata
# (measured: hfs_mark_inconsistent, and a dylib the loader reports as "not a
# mach-o file"). The note beside the image records the phone's volume header;
# a push compares it with the live one and refuses when they differ, because
# the phone booted in between. --save-base after every boot.
#
# A successful push also replaces the base with the image the phone now holds,
# so several pushes in a row need no new dump. Nothing outside userdata
# (/dev/block/sda37) is written.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"

ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
FASTBOOT=${FASTBOOT:-/mnt/c/platform-tools/fastboot.exe}
DEVICE=/dev/block/sda37
DUMP_MIB=${DUMP_MIB:-16384}

base=/root/ios/base.img
note=
work_opt=

save_base=0
dylib= inject= mesa= ui_hook=
flash=0 dry=0 force=0 assume_yes=0

say() { echo "== $*"; }
die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<'EOF'
usage: tools/wsl/push-root.sh --save-base
       tools/wsl/push-root.sh --dylib FILE [--inject FILE] [--mesa DIR]
                              [--flash] [--dry-run] [--force] [--yes]

  --save-base    dump userdata to the base image, fsck it, write the note
  --dylib FILE   mondrian-gl.dylib to install into the copy
  --ui-hook FILE the userland hook dylib to install into the copy
  --inject FILE  mondrian-inject.dylib to install into the copy
  --mesa DIR     directory holding libOSMesa.8.dylib
  --flash        rewrite userdata from the sparse image instead of pushing the
                 changed blocks (needs fastboot; a 15.5 GiB write)
  --dry-run      count the changed blocks, write nothing to the phone
  --force        push although the base no longer matches the phone (see the
                 corruption note in the header of this script)
  --yes          skip the confirmation --flash asks for
  --base IMAGE   base image (default /root/ios/base.img)
  --note FILE    note beside it (default: IMAGE with .note for the suffix)
  --work IMAGE   copy that gets the install, and becomes the base on success
                 (default: IMAGE with .work.img)

The diff push needs the phone in recovery with adb; --flash needs fastboot.
Environment: ADB, FASTBOOT, DUMP_MIB, PUSH_STAGE.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--save-base) save_base=1 ;;
	--flash) flash=1 ;;
	--dry-run) dry=1 ;;
	--force) force=1 ;;
	--yes) assume_yes=1 ;;
	-h|--help) usage; exit 0 ;;
	--dylib|--ui-hook|--inject|--mesa|--base|--note|--work)
		option=$1 value=${2:-}
		[ -n "$value" ] || die "$option needs a value"
		case "$option" in
		--dylib) dylib=$value ;;
		--ui-hook) ui_hook=$value ;;
		--inject) inject=$value ;;
		--mesa) mesa=$value ;;
		--base) base=$value ;;
		--note) note=$value ;;
		--work) work_opt=$value ;;
		esac
		shift ;;
	*) die "unknown argument $1 (try --help)" ;;
	esac
	shift
done

# The note always sits beside the image, so --base moves both.
[ -n "$note" ] || note=${base%.img}.note

note_get() {
	[ -f "$note" ] || return 0
	sed -n "s/^$1=//p" "$note" | head -1
}

need_fsck() {
	command -v fsck.hfsplus >/dev/null 2>&1 ||
		die "no fsck.hfsplus: apt install hfsprogs (docs/BUILD_LINUX.md)"
}

# The HFS+ volume header (512 bytes at offset 1024) carries the modify and
# check dates, so it changes on every metadata write and on no other block:
# a hash of it is enough to tell whether the volume moved since the dump.
hdr_file() {
	[ "$(wc -c <"$1")" -ge 1536 ] || die "$1 is too small to hold an HFS+ volume header"
	dd if="$1" bs=512 skip=2 count=1 2>/dev/null | sha256sum | cut -d' ' -f1
}

hdr_phone() {
	local tmp bytes hash
	tmp=$(mktemp "${TMPDIR:-/tmp}/push-root-hdr.XXXXXX")
	if ! "$ADB" exec-out "dd if=$DEVICE bs=512 skip=2 count=1 2>/dev/null" >"$tmp"; then
		rm -f "$tmp"
		die "could not read the volume header from the phone"
	fi
	bytes=$(wc -c <"$tmp")
	if [ "$bytes" -ne 512 ]; then
		rm -f "$tmp"
		die "read $bytes bytes of the phone's volume header (want 512): adb is not in a shell that can read $DEVICE"
	fi
	hash=$(sha256sum "$tmp" | cut -d' ' -f1)
	rm -f "$tmp"
	echo "$hash"
}

adb_state() {
	timeout 20 "$ADB" devices 2>/dev/null | tr -d '\r' |
		awk 'NR > 1 && $2 != "" { print $2; exit }'
}

in_recovery() {
	local state prop
	state=$(adb_state) || true
	case "$state" in
	recovery)
		return 0
		;;
	device)
		# TWRP and OrangeFox report themselves as a plain "device"; the
		# property is the cheap way to tell them from a running Android.
		prop=$(timeout 20 "$ADB" shell getprop ro.twrp.version 2>/dev/null | tr -d '\r')
		if [ -n "$prop" ]; then
			return 0
		fi
		prop=$(timeout 20 "$ADB" shell getprop ro.bootmode 2>/dev/null | tr -d '\r')
		if [ "$prop" = recovery ]; then
			return 0
		fi
		return 1
		;;
	*)
		return 1
		;;
	esac
}

in_fastboot() {
	command -v "$FASTBOOT" >/dev/null 2>&1 || return 1
	timeout 30 "$FASTBOOT" devices 2>/dev/null | grep -q .
}

need_recovery() {
	local state
	command -v "$ADB" >/dev/null 2>&1 ||
		die "no adb at $ADB: set ADB to the Windows adb.exe (USB is only visible to it)"
	if in_recovery; then
		return 0
	fi
	if in_fastboot; then
		die "the phone is in fastboot: the diff push needs recovery with adb (push-blocks stages the blocks in the recovery's /tmp). Boot a recovery image first, or add --flash."
	fi
	state=$(adb_state) || true
	case "$state" in
	device)
		die "adb sees the phone running, not in recovery: 'adb reboot recovery', then run this again (the iOS kernel has no adb, so a push always goes through recovery)"
		;;
	unauthorized)
		die "adb reports the phone as unauthorized: accept the debugging prompt on the phone"
		;;
	'')
		die "no phone on adb: put it in recovery for the diff push, or in fastboot and add --flash"
		;;
	*)
		die "adb reports the phone as '$state', not recovery"
		;;
	esac
}

# A leftover fastboot.exe keeps the USB handle open; the next flash then dies
# with "Write to device failed (Invalid argument)" while the phone sits in
# fastboot, which reads like a bootloader problem and is not one.
orphan_fastboot() {
	command -v tasklist.exe >/dev/null 2>&1 || return 1
	tasklist.exe /FI "IMAGENAME eq fastboot.exe" /NH 2>/dev/null |
		tr -d '\r' | grep -qi 'fastboot\.exe'
}

stale() {
	local reason=$1
	if [ "$force" = 1 ]; then
		echo "warning: $reason" >&2
		echo "warning: --force given, pushing anyway; if this base is older than the" >&2
		echo "warning: phone's volume the push corrupts it and only --save-base (dump)" >&2
		echo "warning: plus fsck.hfsplus -fy on that dump brings it back." >&2
		return 0
	fi
	cat >&2 <<EOF
error: $reason
The kernel mounts the iOS root read-write (rootrw=1) and writes to it on every
boot, so a base older than the phone's volume is not merely stale: a push from
it writes file data onto blocks the volume now uses for metadata. Measured:
fsck reports the catalog out of order and the loader calls the dylib "not a
mach-o file".
Take a fresh base with 'tools/wsl/push-root.sh --save-base' (dump plus fsck,
the only safe base), or pass --force if you know the volume did not move.
EOF
	exit 1
}

check_base() {
	local size id phone live
	size=$(note_get size)
	id=$(note_get image_id)
	phone=$(note_get phone_id)
	[ -n "$size" ] && [ -n "$id" ] && [ -n "$phone" ] ||
		stale "$note does not record the base's size and volume header"
	[ "$(wc -c <"$base")" = "$size" ] ||
		stale "$base is $(wc -c <"$base") bytes, the note says $size"
	[ "$(hdr_file "$base")" = "$id" ] ||
		stale "$base is not the image the note describes (its volume header differs): an older or replaced base"
	# The base's header is the fsck'd one; phone_id is the volume header as the
	# phone still had it at dump time, which is what a live read must match.
	live=$(hdr_phone)
	[ "$live" = "$phone" ] ||
		stale "the phone's root volume changed since the base was taken (live volume header $live, the base was taken from $phone): the phone booted and wrote to it"
}

write_note() {  # write_note ORIGIN SLOT IMAGE_ID PHONE_ID FSCK
	cat >"$note" <<EOF
# written by tools/wsl/push-root.sh: the phone state this base matches. A diff
# push compares the live volume header with phone_id and refuses on a mismatch.
date=$(date +%F)
origin=$1
slot=$2
size=$(wc -c <"$base")
image_id=$3
phone_id=$4
fsck=$5
EOF
}

save_base_cmd() {
	local dir free sig check first second fsck_result slot phone
	need_recovery
	need_fsck
	dir=$(dirname "$base")
	mkdir -p "$dir"
	free=$(df -Pm "$dir" | awk 'NR == 2 { print $4 }')
	if [ "$free" -lt $((DUMP_MIB + 1024)) ]; then
		die "$dir has ${free} MiB free; the dump needs ${DUMP_MIB} MiB (and a diff push later wants a second copy of it)"
	fi
	# Read the header before the dump: if the partition changes while it is
	# being copied, the dump no longer matches the phone and the diff would be
	# computed against the wrong bytes.
	phone=$(hdr_phone)
	# The note is the marker, so a dump that dies halfway cannot pass for a base.
	rm -f "$note"
	say "dumping userdata ($DEVICE, ${DUMP_MIB} MiB) to $base"
	timeout 3600 "$ADB" exec-out "dd if=$DEVICE bs=1M count=$DUMP_MIB 2>/dev/null" >"$base"
	sig=$(dd if="$base" bs=1 skip=1024 count=2 2>/dev/null)
	# H+ is HFS+, HX is case-sensitive HFS+ (this port's root is case-sensitive)
	case "$sig" in
		H+|HX) ;;
		*) die "$base does not start with an HFS+ volume (signature '$sig'): wrong partition, or a short dump" ;;
	esac
	if [ "$(hdr_file "$base")" != "$phone" ]; then
		rm -f "$base"
		die "the volume header changed while the partition was being dumped: something else wrote to userdata. Run --save-base again."
	fi
	say "checking the dump (fsck.hfsplus -fn)"
	check=$(fsck.hfsplus -fn "$base" 2>&1 || true)
	echo "$check" | tail -2
	case "$check" in
	*"appears to be OK"*) fsck_result=clean ;;
	*) fsck_result=repaired ;;
	esac
	if [ "$fsck_result" = repaired ]; then
		say "repairing the dump (fsck.hfsplus -fy)"
		first=$(fsck.hfsplus -fy "$base" 2>&1 || true)
		echo "$first" | tail -3
		second=$(fsck.hfsplus -fn "$base" 2>&1 || true)
		echo "$second" | tail -2
		case "$second" in
		*"appears to be OK"*) ;;
		*) die "the dump still fails the read-only check; do not base a push on it" ;;
		esac
	fi
	slot=$(timeout 20 "$ADB" shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r_')
	[ -n "$slot" ] || slot=$(timeout 20 "$ADB" shell getprop ro.boot.slot 2>/dev/null | tr -d '\r')
	[ -n "$slot" ] || slot=unknown
	write_note dump "$slot" "$(hdr_file "$base")" "$phone" "$fsck_result"
	say "base ready: $base ($(du -h "$base" | cut -f1), fsck $fsck_result, slot $slot)"
	if [ "$fsck_result" = repaired ]; then
		say "note: the repairs are in the base only; the first write should be --flash so they reach the phone too"
	fi
	say "next: tools/wsl/push-root.sh --dylib out/gpu/mondrian-gl.dylib"
}

# The push wrote every block of IMAGE that differed, and verified each run, so
# the phone now holds IMAGE: make it the base instead of dumping 16 GiB again.
adopt() {
	local image=$1 slot phone
	[ "$image" != "$base" ] || return 0
	slot=$(note_get slot)
	phone=$(hdr_file "$image")
	mv -f "$image" "$base"
	write_note push "${slot:-unknown}" "$phone" "$phone" ok
	say "base updated: $base holds what the phone holds (origin=push); run --save-base after the next boot"
}

flash_cmd() {
	local image=$1 win wpath free sig out rc answer
	if orphan_fastboot; then
		die "fastboot.exe is already running and holds the phone's USB handle: the flash then fails with 'Write to device failed (Invalid argument)' and the phone stays in fastboot. Close it (taskkill.exe /F /IM fastboot.exe) and run this again."
	fi
	sig=$(dd if="$image" bs=1 skip=1024 count=2 2>/dev/null)
	case "$sig" in
		H+|HX) ;;
		*) die "$image does not start with an HFS+ volume (signature '$sig'): flashing it would leave userdata without a root" ;;
	esac
	command -v "$FASTBOOT" >/dev/null 2>&1 ||
		die "no fastboot at $FASTBOOT: set FASTBOOT to the Windows fastboot.exe"
	in_fastboot ||
		die "no device in fastboot mode: hold power and volume down, or 'adb reboot bootloader'"
	mkdir -p "$repo/backup"
	win=$repo/backup/ios-root.simg
	free=$(df -Pm "$repo/backup" | awk 'NR == 2 { print $4 }')
	# fastboot.exe is a Windows binary: it cannot open /root or a WSL /mnt path
	# spelled the Linux way, so the sparse file is written where it can see it.
	say "building the sparse image at $win (${free} MiB free there)"
	python3 "$repo/tools/mk-simg.py" "$image" "$win"
	wpath=$(wslpath -w "$win")
	wpath=${wpath//\\//}
	timeout 60 "$FASTBOOT" getvar current-slot 2>&1 | tr -d '\r' | tail -2 || true
	if [ "$assume_yes" = 0 ]; then
		echo "About to rewrite the whole userdata partition with $wpath"
		echo "That is a 15.5 GiB write over USB. Nothing else is written."
		printf "Type 'yes' to continue: "
		read -r answer || answer=
		[ "$answer" = yes ] || die "aborted"
	fi
	set +e
	out=$(timeout 3600 "$FASTBOOT" -S 64M flash userdata "$wpath" 2>&1)
	rc=$?
	set -e
	echo "$out" | tail -10
	if [ "$rc" -ne 0 ]; then
		case "$out" in
		*"Write to device failed"*)
			die "the transfer failed at the USB layer. The usual cause is another fastboot.exe (or adb) holding the device: check tasklist.exe /FI \"IMAGENAME eq fastboot.exe\" and close it; a marginal cable or port does the same."
			;;
		esac
		die "fastboot failed (exit $rc); the sparse image is still at $win"
	fi
	say "userdata now holds the image; boot it with tools/phone-boot.sh (writes nothing)"
}

push_cmd() {
	local work args out
	[ -f "$base" ] ||
		die "no base image at $base: run 'tools/wsl/push-root.sh --save-base' first (dumps userdata and repairs it with fsck)"
	if [ "$flash" = 0 ]; then
		[ -f "$note" ] ||
			die "no note at $note for $base: the phone state it was taken from is unknown, so a push could land on blocks the volume now uses. Run --save-base."
		# Recovery first: it is also the only state in which the live header
		# can be read, and its error says what to do instead of failing on it.
		need_recovery
		check_base
		if [ "$(note_get fsck)" = repaired ]; then
			echo "warning: fsck repaired $base when it was taken, so the repairs are" >&2
			echo "warning: in the base and not on the phone: a diff carries the install" >&2
			echo "warning: only. --flash writes the repaired volume whole." >&2
		fi
	else
		# A whole-partition write replaces everything, so neither the phone's
		# current content nor the base's age matters: only the image does.
		say "whole-partition write: the age of the base does not matter here"
	fi

	if [ -n "$dylib$inject$mesa$ui_hook" ]; then
		[ -z "$dylib" ] || [ -f "$dylib" ] || die "no $dylib"
		[ -z "$inject" ] || [ -f "$inject" ] || die "no $inject"
		[ -z "$mesa" ] || [ -f "$mesa/libOSMesa.8.dylib" ] || die "no $mesa/libOSMesa.8.dylib"
		[ -z "$ui_hook" ] || [ -f "$ui_hook" ] || die "no $ui_hook"
		need_fsck
		work=${work_opt:-${base%.img}.work.img}
		[ "$work" != "$base" ] || die "--work must not be the base image"
		say "copying $base -> $work"
		rm -f "$work"
		cp --reflink=auto "$base" "$work"
		args=()
		if [ -n "$dylib" ]; then args+=(--gl "$dylib"); fi
		if [ -n "$inject" ]; then args+=(--inject "$inject"); fi
		if [ -n "$mesa" ]; then args+=(--mesa "$mesa"); fi
		if [ -n "$ui_hook" ]; then args+=(--ui-hook "$ui_hook"); fi
		bash "$repo/tools/wsl/install-dylibs.sh" "$work" "${args[@]+"${args[@]}"}"
		say "checking the installed image (fsck.hfsplus -fn)"
		if ! out=$(fsck.hfsplus -fn "$work" 2>&1); then
			echo "$out" | tail -20 >&2
			die "the install left $work inconsistent; nothing was pushed (the copy is kept at $work)"
		fi
	else
		work=$base
	fi

	if [ "$flash" = 1 ]; then
		flash_cmd "$work"
	else
		say "pushing the changed blocks to userdata"
		if [ "$dry" = 1 ]; then
			ADB=$ADB python3 "$repo/tools/wsl/push-blocks.py" "$base" "$work" --dry-run
			say "dry run: nothing was written, the base still matches the phone"
			return 0
		fi
		ADB=$ADB timeout 1800 python3 "$repo/tools/wsl/push-blocks.py" "$base" "$work"
		say "done: boot it with tools/phone-boot.sh (writes nothing)"
	fi
	adopt "$work"
}

if [ "$save_base" = 1 ]; then
	[ -z "$dylib$inject$mesa$ui_hook" ] || die "--save-base takes no install options"
	[ "$flash" = 0 ] || die "--save-base does not flash"
	save_base_cmd
	exit 0
fi

if [ -z "$dylib$inject$mesa$ui_hook" ] && [ "$flash" = 0 ]; then
	usage
	exit 2
fi
[ "$dry" = 0 ] || [ "$flash" = 0 ] || die "--dry-run cannot be combined with --flash"

push_cmd
