#!/bin/bash
# Which of the shim's candidate log paths exists? Each is probed with an 8-byte
# read; on a missing file the control echoes the request instead of bytes.
set -u
cd /mnt/c/Users/Pedro/Documents/GitHub/ios-mondrian || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
for p in /private/var/mobile/Library/Preferences/mondrian-bt.log \
	/private/var/mobile/Library/Logs/mondrian-bt.log \
	/private/var/log/mondrian-bt.log \
	/private/var/tmp/mondrian-bt.log \
	/private/var/mobile/Library/Preferences/mondrian-btd.log \
	/private/var/mobile/Library/Preferences/mondrian-blue.log; do
	echo "== $p"
	python3 tools/usb-ring.py rf "$p" 0 16 | head -c 40
	echo
done
