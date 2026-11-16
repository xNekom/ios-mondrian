#!/bin/bash
# Boot the current kernel on QEMU's virt machine and report where it stops.
#
#   tools/wsl/qemu-run.sh [seconds]
#
# Two things the hard way: the output directory has to be on the Linux side
# (qemu-ios.py binds a QMP unix socket in it, and /mnt/c cannot carry one), and
# the command line must be ONE line. A multi-line string inside the quotes puts
# a newline after rd=vblk0, rdBootVar stops being the string "vblk0", the guest
# falls into the generic IOBSDNameMatching path and waits for a disk for ever --
# which reads exactly like a virtio driver that never probed.
set -u
cd "$(dirname "$0")/../.." || exit 1
SECS=${1:-120}
OUT=${OUT:-/root/qemu-run}
DISK=${DISK:-/root/ios-root.raw}
K=${K:-xnu/out/kernel.development.mondrian}
CMDLINE='debug=0xc serial=3 cpus=1 keepsyms=1 -noprogress rd=vblk0 mondrianspmi=0 launchd_unsecure_cache=1 unentitled_ios_sim_launch=1 rootrw=1 ignition_level=1 wdt=-1 mondriankill=quiet'

rm -rf "$OUT"
mkdir -p "$OUT"

python3 tools/mkadt.py /root/qemu.adt --qemu --board mondrian > /root/qemu-adt.log 2>&1 || {
	tail -5 /root/qemu-adt.log
	exit 1
}
python3 tools/mkpayload.py "$K" /root/qemu.adt /root/qemu-payload.bin \
	--cmdline "$CMDLINE" --board mondrian --allow-silent-boot \
	> /root/qemu-payload.log 2>&1 || {
	tail -8 /root/qemu-payload.log
	exit 1
}

python3 tools/qemu-ios.py /root/qemu-payload.bin "$OUT" --secs "$SECS" \
	--board mondrian --kernel "$K" --disk "$DISK" > "$OUT/run.log" 2>&1
echo "exit $?"

echo "== result"
cat "$OUT/result.json" 2>/dev/null
echo
echo "== panic / abort"
grep -a -m6 -i -e 'panic' -e 'data abort' -e 'KDBRT' "$OUT/serial.txt" "$OUT/run.log" 2>/dev/null | head -10
echo "== virtio"
grep -a -m4 'MONDRIAN VBLK' "$OUT/serial.txt" | head -4
echo "== console tail"
tail -10 "$OUT/serial.txt" 2>/dev/null
