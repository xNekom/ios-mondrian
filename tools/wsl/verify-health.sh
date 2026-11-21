#!/bin/bash
# Final health check of the current boot: presentation, asserts, SpringBoard
# crashes and the Bluetooth power line, from the ring.
set -u
cd /mnt/c/Users/Pedro/Documents/GitHub/ios-mondrian || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING dump out/final-health.txt || exit 1

echo "== present (last three)"
grep -a 'MONDRIAN FB: present' out/final-health.txt | tail -3
echo "== panel"
grep -a 'MONDRIAN FB: panel' out/final-health.txt | tail -1
echo "== ca"
grep -a 'MONDRIAN UI: ca begin' out/final-health.txt | tail -2
echo "== asserts / SpringBoard crashes"
grep -a -c 'Assertion failure in' out/final-health.txt
grep -a -c 'CRASH SpringBoard' out/final-health.txt
echo "== bluetooth"
grep -a 'BTPOWER: powered' out/final-health.txt | tail -1
grep -a 'BTCTL: tx 9 01 01 04' out/final-health.txt | tail -1
echo "== locationd crashes"
grep -a -c 'CRASH locationd' out/final-health.txt
