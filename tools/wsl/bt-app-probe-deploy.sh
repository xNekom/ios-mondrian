#!/bin/bash
# Build and install the Settings-only Bluetooth probe.
#
#   tools/wsl/bt-app-probe-deploy.sh
#
# The probe lives in mondrian-layer-bridge.m behind a program-name check, so it
# has to ride the bridge every app receives; it logs `MONDRIAN BTAPP` lines to
# the console ring (the app sandbox refuses the preferences file) and does
# nothing in any other process. The separate dylib it was meant to dlopen is
# refused by the loader (no AMFI signature), which is why the code is inline.
set -eu
cd "$(dirname "$0")/../.."
root=$(pwd)

bash "$root/tools/build-mondrian-layer-bridge.sh" \
    "$root/out/gpu/mondrian-layer-bridge.dylib" 2>&1 |
    grep -E 'error|dylib:' | tail -2
bash "$root/tools/wsl/attach.sh" >/dev/null
python3 "$root/tools/usb-ring.py" wfile \
    /private/var/vm/mondrian-layer-bridge.dylib \
    "$root/out/gpu/mondrian-layer-bridge.dylib" | tail -1
echo 'installed; restart SpringBoard or boot again to load it'
