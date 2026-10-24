#!/bin/bash
# Build the shim and wrap it in an Android boot image.
#
#   BOARD=sweet|mondrian shim/build.sh [PAYLOAD]
#
# The board selects the MMIO constants (shim/board.h), the magic of the
# payload the shim accepts and the Android boot header:
#
#   sweet     header v2, the stock DTB is embedded in the boot image
#   mondrian  header v3, no DTB: the bootloader passes the live device tree
#             from the untouched vendor_boot partition
#
# The cross compiler defaults to aarch64-linux-gnu-; with the Homebrew
# toolchain use CROSS=aarch64-elf-.
set -euo pipefail
cd "$(dirname "$0")"
BOARD=${BOARD:-sweet}
case "$BOARD" in
	sweet)
		BOARD_DEF=BOARD_SWEET
		BOOT_HEADER=2
		DTB=${DTB:-../dtb/boot_unpacked/dtb}
		;;
	mondrian)
		BOARD_DEF=BOARD_MONDRIAN
		# With a device tree in the image the bootloader patches its
		# /chosen (linux,initrd-start and -end), which is how the shim
		# finds the payload. Without one it uses the live tree from
		# vendor_boot and those pointers stay stale, so the payload is
		# not found. DTB= points at a tree captured from the phone
		# (tools/dtdump.py --build) to embed.
		DTB=${DTB:-}
		;;
	*) echo "error: unknown BOARD '$BOARD' (sweet or mondrian)" >&2; exit 1 ;;
esac
if [ -n "$DTB" ]; then
	BOOT_HEADER=2
else
	BOOT_HEADER=3
fi
CROSS=${CROSS:-aarch64-linux-gnu-}
CC=${CROSS}gcc
OBJCOPY=${CROSS}objcopy
READELF=${CROSS}readelf
NM=${CROSS}nm
# mkbootimg: the packaged one, or the AOSP script in tools/
if command -v mkbootimg >/dev/null; then
	MKBOOTIMG=mkbootimg
else
	MKBOOTIMG="python3 ../tools/mkbootimg.py"
fi
# SMALL_SHIM=1 builds the loader without the bring-up diagnostics: it only
# places the kernel, the device tree and the boot arguments, and jumps.
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra -D$BOARD_DEF ${EXTRA_CFLAGS:-}"
[ -n "${SMALL_SHIM:-}" ] && CFLAGS="$CFLAGS -DSMALL_SHIM -DSHIM_NO_UFS"
# LOGVIEW=1 builds the log viewer: it reads the persistent console log out of
# the end of userdata, prints the last screenful and stops (see shim/ufs.c).
[ -n "${LOGVIEW:-}" ] && CFLAGS="$CFLAGS -DLOGVIEW"
mkdir -p out
for f in start.S shim.c console.c menu.c mmu.c fdt.c loader.c ufs.c libc.c lz4.c spmi.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r out/shim.o out/console.o out/menu.o out/mmu.o out/fdt.o out/loader.o out/ufs.o out/libc.o out/lz4.o out/spmi.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/menu.o out/mmu.o out/fdt.o out/loader.o out/ufs.o out/libc.o out/lz4.o out/spmi.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
end=$($NM out/shim.elf | awk '$3=="_end"{print $1}')
size=$((16#$end))
truncate -s "$size" out/Image
# The xnu payload (tools/mkpayload.py) is appended to the shim image: the
# bootloader loads the "kernel" segment raw, with no cpio and no gzip, so
# this is the one place where the payload survives whatever the ABL does with
# a ramdisk. The shim finds it right after its own code (at _end).
#
# It is compressed with LZ4: the payload is 15MB and the USB link of this
# phone drops in the middle of a transfer that long (the 5MB image goes
# through, the 16MB one does not). The shim unpacks it (shim/lz4.c).
if [ -n "${1:-}" ]; then
	LZ4=${LZ4:-$(command -v lz4 || echo /opt/homebrew/bin/lz4)}
	"$LZ4" -BI -9 -f "$1" out/payload.lz4
	python3 - "$1" out/payload.lz4 out/payload.bin <<-'EOF'
	import os, struct, sys
	raw, comp, out = sys.argv[1], sys.argv[2], sys.argv[3]
	data = open(comp, 'rb').read()
	with open(out, 'wb') as f:
	    f.write(b'LZ4P' + struct.pack('<IQQ', 1, os.path.getsize(raw), len(data)))
	    f.write(data)
	EOF
	cat out/payload.bin >> out/Image
fi
# Ramdisk: an empty newc cpio (ABL dislikes a zero-size ramdisk on some
# builds) -> diagnostics.
if true; then
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
dtb_arg=()
if [ -n "$DTB" ]; then
	dtb_arg=(--dtb "$DTB")
fi
# bash 3.2 (macOS) treats "${empty[@]}" as an error under set -u
if [ ${#dtb_arg[@]} -gt 0 ]; then
	$MKBOOTIMG --header_version "$BOOT_HEADER" --kernel out/Image --ramdisk out/ramdisk.bin \
		--dtb "$DTB" --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --pagesize 4096 \
		--os_version 13.0.0 --os_patch_level 2035-06 \
		--cmdline "console=null" -o out/shim-boot.img
else
	$MKBOOTIMG --header_version "$BOOT_HEADER" --kernel out/Image --ramdisk out/ramdisk.bin \
		--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --pagesize 4096 \
		--os_version 13.0.0 --os_patch_level 2035-06 \
		--cmdline "console=null" -o out/shim-boot.img
fi
# Host render of the console layout.
gcc -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test
gcc -O1 -Wall -o out/lz4_test lz4.c lz4_test.c
echo "shim built for BOARD=$BOARD (header v$BOOT_HEADER)"
ls -l out/Image out/shim-boot.img
