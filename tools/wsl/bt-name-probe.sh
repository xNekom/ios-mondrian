#!/bin/bash
# Does bluetoothd receive LE reports, and does it ever ask for a name? Needs a
# kernel whose control counts them (0399, the `scan le meta` summary line).
# Opens the Bluetooth pane, lets one discovery cycle run, then kills the daemon
# so the control prints the connection summary; kills are deliberate here and
# launchd starts the daemon again.
#
# Usage: bt-name-probe.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING bl 1024
$RING wait 20

echo "== open Settings > Bluetooth"
$RING tap 205 780
$RING wait 10
$RING tap 720 1112
$RING wait 12
$RING screen out/bt-name-pane.png

echo "== let discovery run"
$RING wait 30
$RING screen out/bt-name-pane-late.png
$RING dump /tmp/bt-name-before.txt >/dev/null
pid=$(grep -a 'BTCTL: connected' /tmp/bt-name-before.txt |
	sed -n 's/.*pid \([0-9]*\).*/\1/p' | tail -1)
echo "== daemon pid ${pid:-none}"
if [ -n "${pid:-}" ]; then
	$RING kill "$pid"
	$RING wait 3
fi

$RING dump out/bt-name-dump.txt >/dev/null
echo "== connection summary"
grep -a 'BTCTL: disconnected' out/bt-name-dump.txt | tail -2
grep -a 'BTCTL: scan le meta' out/bt-name-dump.txt | tail -2
echo "== first reports"
grep -a 'BTCTL: name request\|BTCTL: inquiry eir\|BTCTL: le adv\|BTCTL: le scan rsp\|BTCTL: ext report\|BTCTL: ext scan' out/bt-name-dump.txt | tail -12
echo "== names decoded"
bash tools/wsl/bt-le-names.sh out/bt-name-dump.txt | tail -12
echo "== pane: out/bt-name-pane.png out/bt-name-pane-late.png"
