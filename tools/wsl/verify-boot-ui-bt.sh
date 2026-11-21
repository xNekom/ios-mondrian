#!/bin/bash
# After a RAM boot, with no respring: the boot's embedded hook and the pushed
# app bridge are already in place. The Settings icon and the Bluetooth row are
# the measured panel coordinates (the capture is half scale).
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING bl 1024
$RING wait 45
$RING del /private/var/vm/mondrian-layercsurf-off >/dev/null 2>&1 || true

$RING tap 200 764
$RING wait 6
$RING tap 720 1116
$RING wait 4

$RING screen out/boot-ui-bt.png || exit 1
$RING dump out/boot-ui-bt.txt || exit 1

echo "== kernel"
grep -a -m1 'Darwin Kernel Version' out/boot-ui-bt.txt
echo "== presentation"
grep -a 'MONDRIAN FB: present' out/boot-ui-bt.txt | tail -2
grep -a 'MONDRIAN FB: panel' out/boot-ui-bt.txt | tail -1
grep -a 'MONDRIAN UI: ca begin' out/boot-ui-bt.txt | tail -2
echo "== app bridge"
grep -a 'MONDRIAN BRIDGE\[.*loaded in Preferences' out/boot-ui-bt.txt | tail -1
grep -a '129x129' out/boot-ui-bt.txt | tail -6
echo "== assert and crash"
grep -a -c 'Assertion failure in' out/boot-ui-bt.txt
grep -a 'CRASH SpringBoard' out/boot-ui-bt.txt | tail -2
echo "== bluetooth power"
grep -a 'BTPOWER: powered after' out/boot-ui-bt.txt | tail -2
echo "== LE scan traffic"
grep -a 'BTCTL: tx 4 01 0b 20\|BTCTL: tx 4 01 0c 20\|BTCTL: tx .* 01 0b 20\|BTCTL: tx .* 01 0c 20' out/boot-ui-bt.txt | tail -6
grep -a 'BTCTL: rx' out/boot-ui-bt.txt | grep -a '04 3e' | tail -4
echo "== panel and ring are in out/boot-ui-bt.png and out/boot-ui-bt.txt"
