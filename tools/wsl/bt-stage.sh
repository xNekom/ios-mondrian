#!/bin/bash
# The Bluetooth stages, on the phone, in one boot.
#
#   tools/wsl/bt-stage.sh              # power the part, then the baud stage
#   BTHCI=1 tools/wsl/bt-stage.sh      # also send HCI_Reset (see the warning)
#
# The image carries `mondrianreset=240`: `0127`/`0133`/`0220` flush the ring,
# point the BCB at `boot-fastboot` and reset the SoC, so a kernel that wedges
# here comes back to fastboot without the key combo. The board cmdline ships
# `mondrianreset=0`, so the substitution below is the whole reason this script
# exists.
#
# Stages, in the order that isolates them:
#   btuart power   read-only: cmd-db addresses and the five pins
#   btuart on      the vote plus BT_EN / XO / SW_CTRL, the vendor's sequence
#   btuart baud    the UART on its 14745600 root, proved by loopback
#   btuart hci     HCI_Reset on the wire, only with BTHCI=1
#
# `btuart baud` has wedged the command channel when it followed a `btuart
# power` in the same boot, twice, while two bauds back to back survive; a single
# run cannot tell which of the two is responsible, so `pos` after every stage is
# the tripwire and the split is deliberate.
set -u
cd "$(dirname "$0")/../.." || exit 1
IF=${IFACE:-enx02005e77ee01}
FB=${FB:-/mnt/c/platform-tools/fastboot.exe}
BUSID=${BUSID:-7-1}
OUT=${OUT:-/root/cycle/ring-bt.txt}

CM=$(python3 -c "from tools.boards import BOARDS; print(BOARDS['mondrian'].cmdline.replace('mondrianreset=0', 'mondrianreset=240'))")
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
pos() {
	timeout 20 python3 tools/usb-ring.py pos 2>/dev/null | tail -1
}
echo "want: $(grep -a -o -m1 'Darwin Kernel Version[^;]*' xnu/out/kernel.development.mondrian)"
UP=0
for i in $(seq 1 40); do
	sleep 6
	attach
	if pos | grep -aqE '^[0-9]+$'; then UP=1; break; fi
done
[ "$UP" = 1 ] || { echo "the ring never answered" >&2; exit 1; }
timeout 250 python3 tools/usb-ring.py dump "$OUT" > /dev/null 2>&1
echo "got:  $(grep -a -o -m1 'Darwin Kernel Version[^;]*' "$OUT")"

echo '== what powering the chip touches (read only)'
timeout 60 python3 tools/usb-ring.py btuart power 2>&1 | tail -14
echo "pos: $(pos)"

echo '== power the part: rails, then BT_EN / XO / SW_CTRL'
timeout 90 python3 tools/usb-ring.py btuart on 2>&1 | tail -12
echo "pos: $(pos)"

echo '== the UART on its 14745600 root'
timeout 90 python3 tools/usb-ring.py btuart baud 2>&1 | tail -6
echo "pos: $(pos)"

if [ "${BTHCI:-0}" = 1 ]; then
	echo '== HCI_Reset on the wire (see the warning in this script)'
	timeout 120 python3 tools/usb-ring.py btuart hci 2>&1 | tail -8
	echo "pos: $(pos)"
fi

timeout 250 python3 tools/usb-ring.py dump "$OUT" > /dev/null 2>&1
echo '== the same lines, on the ring'
grep -a -e 'btpower:' -e 'btuart:' "$OUT" | tail -26
