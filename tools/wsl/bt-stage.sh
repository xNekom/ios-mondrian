#!/bin/bash
# The Bluetooth stages, on the phone, in one boot.
#
#   tools/wsl/bt-stage.sh                    # one stage: HCI_Reset + version
#   STAGES="edl115" tools/wsl/bt-stage.sh    # one stage: the ROM names itself
#   STAGES="tx115 edl115" tools/wsl/bt-stage.sh   # two, for a known-good pair
#   BTBAUD=1 tools/wsl/bt-stage.sh           # also the UART loopback
#   BTPROBE=1 tools/wsl/bt-stage.sh          # also the read-only pin/rail probe
#
# One stage per boot is the rule, not a preference: `btuart` programs the SE
# root clock through the RCG, and a **second** RCG change in the same boot takes
# the command channel down (measured with `btuart baud` after another stage, and
# again with `edl115` after `hci115`), while the same stage as the first one in
# the boot survives. `pos` after every stage is the tripwire.
#
# The image carries `mondrianreset=240`: the timer flushes the ring, points the
# BCB at `boot-fastboot` and resets, so a wedged kernel comes back to fastboot
# without the key combo. The board cmdline ships `mondrianreset=0`, so the
# substitution below is the whole reason this script exists.
#
# `btuart power` runs *after* the stages, never between `btuart on` and them:
# with the probe in the middle the wire stage killed the channel.
#
# Reading a wedge: `prev` prints the previous boot's ring, but the window is the
# reader boot's `mondrianprevlines` and the area is replaced by the next boot's
# first flush, so a dead-channel boot needs its own follow-up boot with a big
# window (PREVLINES).
set -u
cd "$(dirname "$0")/../.." || exit 1
IF=${IFACE:-enx02005e77ee01}
FB=${FB:-/mnt/c/platform-tools/fastboot.exe}
BUSID=${BUSID:-$(usbipd.exe list 2>/dev/null |
	grep -aE '1209:0001|18d1:d00d' | awk '{print $1}' | head -1)}
OUT=${OUT:-/root/cycle/ring-bt.txt}
STAGES=${STAGES:-hci115}

CM=$(python3 -c "from tools.boards import BOARDS; print(BOARDS['mondrian'].cmdline.replace('mondrianreset=0', 'mondrianreset=240'))")
echo "cmdline: $(printf '%s' "$CM" | tr ' ' '\n' | grep -a -e mondrianreset -e usb=)"
echo "stages: $STAGES"

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

echo '== power the pins: BT_EN low, XO, BT_EN high, XO low, then qup20'
timeout 90 python3 tools/usb-ring.py btuart on 2>&1 | tail -8
echo "pos: $(pos)"

for stage in $STAGES; do
	if [ "$stage" = "download" ]; then
		echo "== the host-driven download (EDL, config, patch, nvm)"
		timeout 900 python3 tools/bt-download.py \
			--steps "${DLSTEPS:-edl,config,fw,nvm}" \
			--fw "${FW:-/mnt/c/Users/Pedro/mondrian-firmware/bluetooth/hpbtfw21.tlv}" \
			--nvm "${NVM:-/mnt/c/Users/Pedro/mondrian-firmware/bluetooth/hpnv21.bin}"
		echo "pos: $(pos)"
		continue
	fi
	echo "== btuart $stage"
	timeout 120 python3 tools/usb-ring.py btuart "$stage" 2>&1 | tail -12
	echo "pos: $(pos)"
done

if [ "${BTBAUD:-0}" = 1 ]; then
	echo '== the UART loopback on its 14745600 root'
	timeout 90 python3 tools/usb-ring.py btuart baud 2>&1 | tail -6
	echo "pos: $(pos)"
fi

if [ "${BTPROBE:-0}" = 1 ]; then
	echo '== the read-only probe: rails in the cmd-db, the pins'
	timeout 60 python3 tools/usb-ring.py btuart power 2>&1 | tail -14
	echo "pos: $(pos)"
fi

timeout 250 python3 tools/usb-ring.py dump "$OUT" > /dev/null 2>&1
echo '== the same lines, on the ring'
grep -a -e 'btpower:' -e 'btuart:' "$OUT" | tail -24
