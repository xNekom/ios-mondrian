#!/bin/bash
# Read the Settings-only Bluetooth probe after a RAM boot of the current kernel.
#
#   tools/wsl/bt-app-probe-read.sh
#
# The probe lives in mondrian-layer-bridge.m (program name "Preferences") and
# logs `MONDRIAN BTAPP` to the console ring. It needs the boot whose
# `Darwin Kernel Version` is the current build, otherwise bluetoothd exits and
# Settings has no Bluetooth row.
set -u
cd "$(dirname "$0")/../.." || exit 1

bash tools/wsl/attach.sh >/dev/null 2>&1 || { echo 'no phone'; exit 1; }
echo "ring says: $(python3 tools/usb-ring.py pos 2>/dev/null)"
python3 tools/usb-ring.py swipe 720 2900 720 1100 250 >/dev/null
python3 tools/usb-ring.py wait 3
python3 tools/usb-ring.py tap 202 756 >/dev/null
python3 tools/usb-ring.py wait 8
python3 tools/usb-ring.py tap 400 1114 >/dev/null
python3 tools/usb-ring.py wait 40
python3 tools/usb-ring.py screen out/probe-pane.png >/dev/null
python3 tools/usb-ring.py tap 720 880 >/dev/null
python3 tools/usb-ring.py wait 14
python3 tools/usb-ring.py screen out/probe-tap.png >/dev/null
python3 tools/usb-ring.py dump out/probe-ring.txt >/dev/null 2>&1
echo "BTAPP lines: $(grep -ac 'MONDRIAN BTAPP' out/probe-ring.txt)"
grep -a 'MONDRIAN BTAPP' out/probe-ring.txt | head -20
