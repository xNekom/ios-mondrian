#!/bin/bash
# Restart SpringBoard only. The panel can keep the last frame after the
# window server restarts (`respring` kills backboardd); killing SpringBoard
# makes the new process reconnect and present, which is what unsticks the
# screen in the boot after a RAM boot (measured 2026-11-21: fps 0 and dead
# taps before, lock screen and live taps after).
#
# Usage: bt-ui-reset.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING dump /tmp/bt-ui-reset.txt >/dev/null
sp=$(grep -a 'SMP t=' /tmp/bt-ui-reset.txt | tail -1 |
	sed -n 's/.*SpringBoard(\([0-9]*\)).*/\1/p')
echo "== SpringBoard ${sp:-none}"
if [ -n "${sp:-}" ]; then
	$RING kill "$sp" >/dev/null
fi
$RING wait 15 >/dev/null
$RING screen out/bt-ui-reset.png >/dev/null
echo "== out/bt-ui-reset.png"
