#!/usr/bin/env bash
# Read and write an HFS+ image from WSL2, which has no hfsplus driver.
#
#   tools/wsl/hfs-tool.sh setup
#   tools/wsl/hfs-tool.sh put IMAGE DESTDIR SRCDIR     # copy SRCDIR/* to IMAGE:DESTDIR
#   tools/wsl/hfs-tool.sh get IMAGE PATH OUTDIR        # copy IMAGE:PATH to OUTDIR/
#
# put copies the *contents* of SRCDIR into DESTDIR, so a stage that already
# mirrors the root (`stage/private/var/vm/...`) goes in with DESTDIR=/ —
# passing both DESTDIR and the staged path nests it one level deeper, which
# leaves the file the caller meant to replace untouched.
#
# The iOS root is HFS+, and the Linux kernel WSL2 runs is built without
# hfsplus, so it cannot be mounted here. This boots a stock Ubuntu kernel in
# qemu (it has hfsplus.ko), attaches the image as a virtio disk, and does the
# copy inside: the only way to change the root image from Windows without a Mac.
#
# The payload travels as a small ext4 image built with `mke2fs -d` (no loop
# mount and no 9p share), and `get` writes into a second one that is read back
# with debugfs.
set -euo pipefail

CACHE=${CACHE:-$HOME/.cache/ios-mondrian/hfstool}
KVER=${KVER:-6.8.0-147-generic}
DEBS=${DEBS:-/root/hfstool/debs}

say() { echo "== $*"; }
die() { echo "error: $*" >&2; exit 1; }

setup() {
	mkdir -p "$CACHE/debs" "$CACHE/root"
	if [ ! -f "$CACHE/debs/linux-image.deb" ]; then
		ls "$DEBS"/linux-image-*.deb >/dev/null 2>&1 ||
			die "$DEBS/linux-image-*.deb missing (apt-get download linux-image-$KVER linux-modules-$KVER linux-modules-extra-$KVER)"
		cp "$DEBS"/linux-image-*.deb "$CACHE/debs/linux-image.deb"
		cp "$DEBS"/linux-modules-6*.deb "$CACHE/debs/linux-modules.deb"
		# hfsplus lives in modules-extra on Ubuntu
		cp "$DEBS"/linux-modules-extra-*.deb "$CACHE/debs/linux-modules-extra.deb" 2>/dev/null || true
	fi
	say "unpacking the kernel and its modules"
	rm -rf "$CACHE/kernel"
	mkdir -p "$CACHE/kernel"
	dpkg-deb -x "$CACHE/debs/linux-image.deb" "$CACHE/kernel"
	dpkg-deb -x "$CACHE/debs/linux-modules.deb" "$CACHE/kernel"
	[ -f "$CACHE/debs/linux-modules-extra.deb" ] &&
		dpkg-deb -x "$CACHE/debs/linux-modules-extra.deb" "$CACHE/kernel"
	local kdir="$CACHE/kernel/boot"
	local mod="$CACHE/kernel/lib/modules/$KVER/kernel/fs/hfsplus/hfsplus.ko"
	[ -f "$mod" ] || mod="$CACHE/kernel/lib/modules/$KVER/kernel/fs/hfsplus/hfsplus.ko.zst"
	[ -f "$mod" ] || die "hfsplus.ko not in the modules packages ($mod)"
	# hfsplus mounts with the utf8 nls by default; without it the kernel says
	# "unable to load nls for utf8" and mount fails with EINVAL
	local nls="$CACHE/kernel/lib/modules/$KVER/kernel/fs/nls/nls_utf8.ko"
	[ -f "$nls" ] || nls="$CACHE/kernel/lib/modules/$KVER/kernel/fs/nls/nls_utf8.ko.zst"
	[ -f "$nls" ] || die "nls_utf8.ko not in the modules packages ($nls)"
	if [ "${mod##*.}" = zst ]; then
		command -v zstd >/dev/null || die "hfsplus.ko is zstd-compressed; apt install zstd"
		zstd -df "$mod" -o "$CACHE/hfsplus.ko"
		mod="$CACHE/hfsplus.ko"
	fi
	if [ "${nls##*.}" = zst ]; then
		zstd -df "$nls" -o "$CACHE/nls_utf8.ko"
		nls="$CACHE/nls_utf8.ko"
	fi
	cp "$kdir/vmlinuz-$KVER" "$CACHE/vmlinuz"

	say "building the initramfs"
	local root="$CACHE/root"
	rm -rf "$root"
	mkdir -p "$root/bin" "$root/sbin" "$root/proc" "$root/sys" "$root/dev" "$root/mnt" "$root/src" \
		"$root/lib/modules/$KVER/kernel/fs/hfsplus" "$root/lib/modules/$KVER/kernel/fs/nls"
	cp /bin/busybox "$root/bin/busybox"
	cp "$mod" "$root/lib/modules/$KVER/kernel/fs/hfsplus/"
	cp "$nls" "$root/lib/modules/$KVER/kernel/fs/nls/"
	depmod -b "$root" "$KVER"
	for applet in sh mount umount cat tr sed mkdir cp rm sync poweroff echo ls; do
		ln -sf busybox "$root/bin/$applet"
	done
	cat >"$root/init" <<'INIT'
#!/bin/sh
# Runs inside the helper VM: mount the HFS+ image and copy one way or the other.
export PATH=/bin:/sbin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs dev /dev

mode=$(sed -n 's/.*mode=\([a-z]*\).*/\1/p' /proc/cmdline)
dest=$(sed -n 's/.*dest=\([^ ]*\).*/\1/p' /proc/cmdline)
echo "HFS-TOOL: mode=$mode dest=$dest"

modprobe nls_utf8 || echo "HFS-TOOL: no nls_utf8 module"
modprobe hfsplus || { echo "HFS-TOOL: no hfsplus module"; poweroff -f; }
echo "HFS-TOOL: filesystems: $(grep -w hfsplus /proc/filesystems || echo none)"
# `force` is the hfsplus mount option that allows read-write on a journaled
# volume the kernel would otherwise mount read-only; fall back to plain rw so
# the failure message says which one it was.
if ! mount -t hfsplus -o rw,force /dev/vda /mnt; then
	if ! mount -t hfsplus -o rw /dev/vda /mnt; then
		echo "HFS-TOOL: cannot mount the image"
		dmesg | tail -12
		poweroff -f
	fi
fi
echo "HFS-TOOL: image mounted"
# read-only means the volume is dirty and the kernel refused it (journal); the
# copy then fails with EROFS and this line is the reason
grep ' /mnt ' /proc/mounts
ls /mnt | head -5

case "$mode" in
put)
	if ! mount -t ext4 -o ro /dev/vdb /src; then
		echo "HFS-TOOL: cannot mount the payload"
		poweroff -f
	fi
	mkdir -p "/mnt$dest" || poweroff -f
	cp -a /src/. "/mnt$dest"/ 2>&1 || { echo "HFS-TOOL: copy failed"; poweroff -f; }
	sync
	echo "HFS-TOOL: put done"
	;;
get)
	if ! mount -t ext4 /dev/vdb /src; then
		echo "HFS-TOOL: cannot mount the output disk"
		poweroff -f
	fi
	rm -rf /src/out
	mkdir -p /src/out
	cp -a "/mnt$dest" /src/out/ || { echo "HFS-TOOL: read failed"; poweroff -f; }
	sync
	echo "HFS-TOOL: get done"
	;;
*)
	echo "HFS-TOOL: unknown mode"
	;;
esac
umount /mnt 2>/dev/null || true
poweroff -f
INIT
	chmod +x "$root/init"
	( cd "$root" && find . | cpio -o -H newc --quiet | gzip -9 ) >"$CACHE/initramfs.gz"
	ls -l "$CACHE/vmlinuz" "$CACHE/initramfs.gz"
}

run_vm() {  # run_vm IMAGE PAYLOAD MODE DEST
	local image=$1 payload=$2 mode=$3 dest=$4 log
	# not on the same `local` line: its words are all expanded before any
	# assignment, so $mode would still be unset under `set -u`
	log=$CACHE/vm-$mode.log
	# a qcow2 overlay on the dumped image avoids copying 16 GiB to change a dylib
	local imagefmt=raw
	case "$image" in *.qcow2) imagefmt=qcow2 ;; esac
	set +e
	timeout 600 qemu-system-x86_64 \
		-m 1024 -smp 2 -nographic -no-reboot \
		-kernel "$CACHE/vmlinuz" -initrd "$CACHE/initramfs.gz" \
		-append "console=ttyS0 panic=1 quiet mode=$mode dest=$dest" \
		-drive "file=$image,format=$imagefmt,if=virtio,cache=writeback" \
		-drive "file=$payload,format=raw,if=virtio,cache=writeback" \
		>"$log" 2>&1
	local rc=$?
	set -e
	grep -a 'HFS-TOOL' "$log" | tail -6
	if [ $rc -ne 0 ] && ! grep -aq "HFS-TOOL: $mode done" "$log"; then
		echo "error: the helper VM failed (rc=$rc); log: $log" >&2
		return 1
	fi
	grep -aq "HFS-TOOL: $mode done" "$log" || { echo "error: no confirmation in $log" >&2; return 1; }
}

cmd_put() {
	local image=$1 dest=$2 src=$3 payload=$CACHE/payload.img
	[ -f "$image" ] || die "no image at $image"
	[ -d "$src" ] || die "no directory at $src"
	set -- "$image" "$dest" "$src"
	rm -f "$payload"
	local size=$(( $(du -sk "$src" | cut -f1) + 32768 ))
	mke2fs -q -t ext4 -d "$src" -F "$payload" "${size}k"
	say "put $src -> $image:$dest"
	run_vm "$image" "$payload" put "$dest"
}

cmd_get() {
	local image=$1 path=$2 out=$3 payload=$CACHE/out.img
	[ -f "$image" ] || die "no image at $image"
	mkdir -p "$out"
	rm -f "$payload"
	mke2fs -q -t ext4 -F "$payload" 256M
	say "get $image:$path -> $out"
	run_vm "$image" "$payload" get "$path"
	debugfs -R "rdump /out $out" "$payload" >/dev/null 2>&1 ||
		die "debugfs could not read $path out of the output disk"
	find "$out" -maxdepth 2 | head -5
}

case "${1:-}" in
setup) setup ;;
put) shift; [ $# -eq 3 ] || die "usage: hfs-tool.sh put IMAGE DESTDIR SRCDIR"; cmd_put "$@" ;;
get) shift; [ $# -eq 3 ] || die "usage: hfs-tool.sh get IMAGE PATH OUTDIR"; cmd_get "$@" ;;
*) sed -n '2,12p' "$0"; exit 2 ;;
esac
