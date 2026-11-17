#!/bin/bash
# The Bluetooth UART stages, on the phone, in one boot.
#
#   tools/wsl/bt-stage.sh              # baud twice, then the XO loopback
#   BTHCI=1 tools/wsl/bt-stage.sh      # also run the wire stage (see the warning)
#
# The image carries `mondrianreset=120`: `0127`/`0133`/`0220` flush the ring,
# point the BCB at `boot-fastboot` and reset the SoC two minutes after boot, so
# a kernel that wedges here comes back to fastboot without the key combo. The
# board cmdline ships `mondrianreset=0`, so the substitution below is the whole
# reason this script exists.
#
# `BTHCI=1` is off by default: `btuart hci` drives the physical TX pin into an
# unpowered chip and, in two boots, left the command channel dead (ICMP fine,
# UDP 5141 silent). docs/MONDIAN_WIRELESS.md has the reasoning; it stays behind
# a flag until the pinmux and the SE interrupt are ours.
set -u
cd "$(dirname "$0")/../.." || exit 1
IF=${IFACE:-enx02005e77ee01}
FB=${FB:-/mnt/c/platform-tools/fastboot.exe}
BUSID=${BUSID:-7-1}
OUT=${OUT:-/root/cycle/ring-bt.txt}

CM=$(python3 -c "from tools.boards import BOARDS; print(BOARDS['mondrian'].cmdline.replace('mondrianreset=0', 'mondrianreset=120'))")
echo "cmdline: $(printf '%s' "$CM" | tr ' ' '\n' | grep -a -e mondrianreset -e usb=)"

python3 tools/mkadt.py shim/out/mondrian.adt --board mondrian > /tmp/adt.log 2>&1
python3 tools/mkpayload.py xnu/out/kernel.development.mondrian shim/out/mondrian.adt \
	shim/out/payload.bin --board mondrian --cmdline "$CM" > /tmp/payload.log 2>&1 ||
	{ tail -5 /tmp/payload.log; exit 1; }
BOARD=mondrian SMALL_SHIM=1 DTB=dtb/mondrian-live.dtb \
	shim/build.sh shim/out/payload.bin > /tmp/shim.log 2>&1 || { tail -5 /tmp/shim.log; exit 1; }

bash tools/wsl/flash-image.sh --no-build || exit 1

attach() {
	usbipd.exe attach --wsl --busid "$BUSID" > /dev/null 2>&1
	sleep 4
	ip link set "$IF" up 2>/dev/null
	ip addr add 192.168.7.1/24 dev "$IF" 2>/dev/null
}
echo "want: $(grep -a -o -m1 'Darwin Kernel Version[^;]*' xnu/out/kernel.development.mondrian)"
UP=0
for i in $(seq 1 40); do
	sleep 6
	attach
	timeout 20 python3 tools/usb-ring.py pos > /root/cycle/pos.txt 2>&1
	if grep -a -qE '^[0-9]+$' /root/cycle/pos.txt; then UP=1; break; fi
done
[ "$UP" = 1 ] || { echo "the ring never answered" >&2; exit 1; }
timeout 250 python3 tools/usb-ring.py dump "$OUT" > /dev/null 2>&1
echo "got:  $(grep -a -o -m1 'Darwin Kernel Version[^;]*' "$OUT")"

echo '== what powering the chip would touch (read only)'
timeout 60 python3 tools/usb-ring.py btuart power 2>&1 | tail -14
echo "pos: $(timeout 20 python3 tools/usb-ring.py pos 2>&1 | tail -1)"

echo '== exact 115200 on a fresh engine (root 14745600, divider 8)'
timeout 90 python3 tools/usb-ring.py btuart baud 2>&1 | tail -6
echo "pos: $(timeout 20 python3 tools/usb-ring.py pos 2>&1 | tail -1)"

echo '== the same again: a stage must not depend on the one before it'
timeout 90 python3 tools/usb-ring.py btuart baud 2>&1 | tail -6
echo "pos: $(timeout 20 python3 tools/usb-ring.py pos 2>&1 | tail -1)"

echo '== loopback at the XO rate (120000), the reference'
timeout 90 python3 tools/usb-ring.py btuart loop 2>&1 | tail -5
echo "pos: $(timeout 20 python3 tools/usb-ring.py pos 2>&1 | tail -1)"

if [ "${BTHCI:-0}" = 1 ]; then
	echo '== HCI_Reset on the wire (see the warning in this script)'
	timeout 120 python3 tools/usb-ring.py btuart hci 2>&1 | tail -6
	echo "pos: $(timeout 20 python3 tools/usb-ring.py pos 2>&1 | tail -1)"
fi

timeout 250 python3 tools/usb-ring.py dump "$OUT" > /dev/null 2>&1
echo '== the same lines, on the ring'
grep -a 'btuart:' "$OUT" | tail -18
