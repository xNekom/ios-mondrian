#!/bin/bash
# Which of the shim's candidate log paths exists on this boot? The daemon picks
# the first it can open, so a read that fails on the first and works on the
# second is the answer; `rf` prints its own error line for a missing file.
#
# Usage: bt-find-log.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
for p in \
	/private/var/mobile/Library/Preferences/mondrian-bt.log \
	/private/var/mobile/Library/Logs/mondrian-bt.log \
	/private/var/log/mondrian-bt.log \
	/private/var/tmp/mondrian-bt.log \
	/private/var/mobile/Library/Preferences/mondrian-bt-power.log; do
	printf '%s -> ' "$p"
	$RING rf "$p" 0 120 2>&1 | head -2 | tr '\n' ' '
	echo
done
