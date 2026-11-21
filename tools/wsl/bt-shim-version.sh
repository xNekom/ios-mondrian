#!/bin/bash
# Is the deployed shim actually the one running? The constructor's first line
# carries its version; read it after a restart.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"

bash tools/wsl/attach.sh || exit 1
$RING wfile /private/var/vm/mondrian-bt.dylib out/gpu/mondrian-bt.dylib || exit 1
$RING wait 20
echo "== first 600 bytes of the daemon log"
python3 tools/usb-ring.py rf /private/var/mobile/Library/Preferences/mondrian-btd.log 0 600
echo
echo "== next 400"
python3 tools/usb-ring.py rf /private/var/mobile/Library/Preferences/mondrian-btd.log 600 400
