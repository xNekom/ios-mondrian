#!/bin/bash
# Discovery proof: the pane lists a device, so the controller must have sent an
# Inquiry Result event carrying its address. BD_ADDR travels least significant
# byte first; search both byte orders and the printable form.
set -u
cd /mnt/c/Users/Pedro/Documents/GitHub/ios-mondrian || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING screen out/bt-discovery.png || exit 1
$RING dump out/bt-discovery.txt || exit 1

echo "== inquiry results (event 0x02) and the device address"
grep -a 'BTCTL: rx.*04 02\|BTCTL: rx.*b0 ac 82\|BTCTL: rx.*3c 22 15 82 ac b0' out/bt-discovery.txt | tail -8
echo "== bd_addr strings anywhere in the ring"
grep -a -i 'b0:ac:82\|B0:AC:82\|3c 22 15 82 ac b0\|b0 ac 82 15 22 3c' out/bt-discovery.txt | tail -6
echo "== last transport and inquiry"
grep -a 'BTCTL: connected\|BTCTL: disconnected' out/bt-discovery.txt | tail -4
awk '/SMP t=/ { t = $0 }
     /BTCTL: tx 9 01 01 04/ { print t; print "    " $0 }' out/bt-discovery.txt | tail -4
echo "== panel is out/bt-discovery.png"
