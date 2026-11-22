#!/bin/bash
# Open Settings > Bluetooth and read what the controller is told about being
# discoverable. The pane says the iPhone is discoverable only while it is open,
# and that is a `Write Scan Enable` (0x0C1A) to the controller: if the command
# never reaches the shim, no PC can find the phone and pairing cannot start.
#
# Usage: bt-discoverable-check.sh [OUT.png]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
OUT=${1:-out/bt-discoverable.png}

bash tools/wsl/attach.sh || exit 1
$RING tap 360 1000 >/dev/null
$RING wait 2 >/dev/null
$RING tap 202 756 >/dev/null
$RING wait 8 >/dev/null
$RING tap 400 1106 >/dev/null
$RING wait 8 >/dev/null
$RING screen "$OUT"
$RING dump out/bt-discoverable-ring.txt >/dev/null 2>&1
echo "== exec/exit Preferences"
grep -a 'exec Preferences\|exit Preferences' out/bt-discoverable-ring.txt | tail -2
echo "== counters"
grep -a 'scan le meta' out/bt-discoverable-ring.txt | tail -1
bash tools/wsl/bt-tail.sh \
	/private/var/mobile/Library/Preferences/mondrian-bt-power.log \
	out/bt-discoverable.log 6000 >/dev/null 2>&1
echo "== scan enable commands in the newest 6 KB"
grep -a '0c1a\|scan enable' out/bt-discoverable.log | tail -4
echo "== last hci requests"
grep -a 'hci req ' out/bt-discoverable.log | tail -4
