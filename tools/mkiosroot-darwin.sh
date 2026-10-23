#!/bin/bash
# Build the iOS root on macOS: one case-sensitive HFS+ image holding an iOS OS
# root filesystem plus its cryptexes, for the userdata partition (rd=ufsroot0).
#
#   sudo tools/mkiosroot.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE]
#
# mkiosroot.sh dispatches here on Darwin; read its header for what the image
# contains and why. The Linux path reads the APFS images through apfs-fuse and
# writes the HFS+ volume with hfsprogs; macOS does both natively (hdiutil and
# newfs_hfs), which is also the only way to keep the real owners: the volumes
# must be mounted with -owners on, because the default noowners mount reports
# every file as owned by the user running the copy.
#
# Run it with sudo. Ownership is the point: /sbin/launchd and the daemons'
# configurations must be root:wheel, and only root can create those owners
# inside the image.
set -euo pipefail

[[ $# -ge 4 ]] || { sed -n '2,10p' "$0"; exit 2; }
os=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
sysos=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
appos=$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
out=$4 size=${5:-16G}
[[ -e $out ]] && { echo "refusing to overwrite $out" >&2; exit 1; }
[[ $EUID -eq 0 ]] || {
	echo "error: run it with sudo (the image needs root:wheel owners)" >&2
	exit 1
}
for d in "$os" "$sysos" "$appos"; do
	[[ -f $d ]] || { echo "error: $d not found" >&2; exit 1; }
done
for t in hdiutil newfs_hfs rsync fsck_hfs; do
	command -v "$t" >/dev/null || { echo "error: missing $t" >&2; exit 1; }
done

work=$(mktemp -d)
attached=()
cleanup() {
	for m in ${attached[@]+"${attached[@]}"}; do
		hdiutil detach -quiet "$m" 2>/dev/null || true
	done
	rmdir "$work" 2>/dev/null || true
}
trap cleanup EXIT

# hdiutil attaches every volume of the image and prints one line per volume;
# the last field of a mounted one is its mount point. The mount point comes
# back in MP (not on stdout): a command substitution would mount in a subshell
# and the list of mounts to detach would never reach the trap.
attach_apfs() {
	MP=$(hdiutil attach -nobrowse -readonly -noverify -owners on "$1" |
	    awk '/\/Volumes\//{print $NF; exit}')
	[[ -n $MP ]] || { echo "error: $1 did not mount" >&2; exit 1; }
	attached=("$MP" ${attached[@]+"${attached[@]}"})
}

echo "== attaching the APFS images"
attach_apfs "$os"; osmp=$MP
attach_apfs "$sysos"; sysmp=$MP
attach_apfs "$appos"; appmp=$MP
echo "   OS:     $osmp"
echo "   System: $sysmp"
echo "   App:    $appmp"
[[ -x $osmp/sbin/launchd ]] || {
	echo "error: $osmp is not the OS volume (no sbin/launchd)" >&2
	exit 1
}

echo "== creating $out ($size, case-sensitive journaled HFS+)"
# newfs_hfs only formats devices, and hdiutil create no longer writes a raw
# image, so: blank file -> attach it as a disk -> format the device -> mount.
mkfile "$size" "$out"
dev=$(hdiutil attach -nomount -noverify -imagekey diskimage-class=CRawDiskImage \
    "$out" | awk '/^\/dev\/disk/{print $1; exit}')
[[ -n $dev ]] || { echo "error: could not attach $out" >&2; exit 1; }
newfs_hfs -s -J -U 0 -G 0 -v iOSRoot "$dev" >/dev/null
hdiutil detach -quiet "$dev"
mkdir "$work/root"
hdiutil attach -nobrowse -noverify -owners on -mountpoint "$work/root" "$out" \
    >/dev/null
attached=("$work/root" ${attached[@]+"${attached[@]}"})

copy() {
	echo "copying $1 -> ${2#"$work/root"}"
	mkdir -p "$2"
	rsync -aH --numeric-ids "$1/" "$2/"
}
copy "$osmp" "$work/root"
copy "$sysmp" "$work/root/private/preboot/Cryptexes/OS"
copy "$appmp" "$work/root/private/preboot/Cryptexes/App"

# Shared cache where dyld looks at ignition level 1: hard links, no extra space.
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$work/root/System/Library/Caches/com.apple.dyld"
for f in "$work/root/$dsc"/*; do
	[[ -e $f ]] || continue
	ln "$f" "$work/root/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# dyld does not search the cryptexes at ignition level 1: hard-link every
# cryptex file that has no counterpart in the OS root (libobjc-trampolines,
# libffi-trampolines, libstdc++, ...) to its root path.
for c in OS App; do
	(cd "$work/root/private/preboot/Cryptexes/$c" &&
	    find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if [[ ! -e $work/root/$f && ! -L $work/root/$f ]]; then
			mkdir -p "$work/root/$(dirname "$f")"
			src=$work/root/private/preboot/Cryptexes/$c/$f
			# a symlink cannot be hard-linked portably: copy those
			if [[ -L $src ]]; then cp -P "$src" "$work/root/$f"
			else ln "$src" "$work/root/$f"; fi
		fi
	done
done

# logd's log stores, normally made at restore: it checks owner _logd (272) and
# mode, plus a .migrated marker, else asks a helper and crashes
# ("BUG IN LIBTRACE: Failed to migrate directory").
db=$work/root/private/var/db
install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

# System keybag for the built-in AppleKeyStore (no passcode).
install -d -m 0700 -o 0 -g 0 "$work/root/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' \
	> "$work/systembag.kb"
install -m 0600 -o 0 -g 0 "$work/systembag.kb" \
	"$work/root/private/var/keybags/systembag.kb"

# The bring-up tweaks need exactly this state (root, the image mounted
# read-write), so they run here; APPLY_TWEAKS=0 builds a stock iOS root.
tweaks=$(cd "$(dirname "$0")" && pwd)/ios-root-tweaks.py
if [[ ${APPLY_TWEAKS:-1} == 1 && -f $tweaks ]]; then
	echo "== applying the bring-up tweaks ($tweaks)"
	python3 "$tweaks" "$work/root"
fi

df -h "$work/root"
free_mb=$(df -m "$work/root" | awk 'END{print $4}')
echo "== detaching $out"
hdiutil detach -quiet "$work/root"

# fsck_hfs only takes a device (the file form is refused since macOS 26), so
# attach the image again without mounting it.
echo "== checking the volume"
dev=$(hdiutil attach -nomount -noverify -imagekey diskimage-class=CRawDiskImage \
    "$out" | awk '/^\/dev\/disk/{print $1; exit}')
[[ -n $dev ]] || { echo "error: could not attach $out for fsck" >&2; exit 1; }
fsck_hfs -f -y "$dev" | grep -v 'Illegal name' || true
fsck_hfs -f -n "$dev" || { hdiutil detach -quiet "$dev"; exit 1; }
hdiutil detach -quiet "$dev"

sig=$(dd if="$out" bs=1 skip=1024 count=2 2>/dev/null)
[[ $sig == HX ]] || { echo "error: signature is '$sig', not HX (HFSX)" >&2; exit 1; }

# mkfile makes the image root-only; whoever flashes it (tools/flash-root.sh)
# reads it as the normal user.
chmod 0644 "$out"

echo "== $out ($(du -h "$out" | cut -f1), $(stat -f%z "$out") bytes), $free_mb MiB free inside"
if [[ $free_mb -lt 2048 ]]; then
	echo "warn: less than 2 GiB free on the volume; iOS needs room for /private/var" >&2
	echo "      rebuild with a bigger size (the 6th argument)" >&2
fi
