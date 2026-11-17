#!/bin/bash
# Run the host-side Qualcomm download against a booted kernel.
#
# The image has to be flashed first (`tools/wsl/bt-stage.sh` does that); this
# script only attaches the USB link, waits for the ring and drives
# tools/bt-download.py, which does `btuart on`, `btuart hci115` (the first root
# clock change of the boot) and then the EDL exchange and the blobs.
#
#   tools/wsl/bt-download.sh                 # everything
#   STEPS=edl tools/wsl/bt-download.sh       # only the identity commands
#
# The image must carry `mondrianreset=240`; bt-stage adds it, so flash with
# that script and then run this one.
set -u
cd "$(dirname "$0")/../.." || exit 1
IF=${IFACE:-enx02005e77ee01}
BUSID=${BUSID:-$(usbipd.exe list 2>/dev/null |
	grep -aE '1209:0001|18d1:d00d' | awk '{print $1}' | head -1)}
FW=${FW:-/mnt/c/Users/Pedro/mondrian-firmware/bluetooth/hpbtfw21.tlv}
NVM=${NVM:-/mnt/c/Users/Pedro/mondrian-firmware/bluetooth/hpnv21.bin}
STEPS=${STEPS:-on,hci115,flow,edl,fw,nvm,post}

usbipd.exe attach --wsl --busid "$BUSID" > /dev/null 2>&1
sleep 3
ip link set "$IF" up 2>/dev/null
ip addr add 192.168.7.1/24 dev "$IF" 2>/dev/null

for i in $(seq 1 20); do
	if timeout 10 python3 tools/usb-ring.py pos 2>/dev/null | grep -aqE '^[0-9]+$'; then
		break
	fi
	sleep 3
done
echo "pos: $(timeout 10 python3 tools/usb-ring.py pos 2>/dev/null | tail -1)"
echo "fw:  $FW"
echo "nvm: $NVM"

timeout 900 python3 tools/bt-download.py --steps "$STEPS" --fw "$FW" --nvm "$NVM"
echo "pos after: $(timeout 10 python3 tools/usb-ring.py pos 2>/dev/null | tail -1)"
