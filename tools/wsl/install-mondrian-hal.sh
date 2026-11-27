#!/bin/bash
# Install the Mondrian speaker HAL driver into a running phone, over USB.
#
#   tools/wsl/install-mondrian-hal.sh [DRIVER.driver]
#
# No reflash: the iOS root is writable, and 0508 gives the command channel a
# `mkdir` so the bundle's own directory can be created. The files go in with
# `wfile`. The path is the one Apple's own HAL plug-ins use in a stock iOS root
# (`/System/Library/Audio/Plug-Ins/HAL/AppleUSBAudio.driver`) and the one the
# only working third-party port on iOS loads from; `/Library/...` is a macOS
# convention. Restarting mediaserverd is what makes the HAL loader look at the
# directory; the console ring then answers with the driver's own "mondrian
# hal:" lines.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
dir=${1:-/root/mondrian-hal/MondrianAudio.driver}
hal=/System/Library/Audio/Plug-Ins/HAL/MondrianAudio.driver

[ -f "$dir/MondrianAudio" ] || { echo "error: $dir/MondrianAudio not found (run tools/build-mondrian-hal.sh)" >&2; exit 1; }
[ -f "$dir/Info.plist" ] || { echo "error: $dir/Info.plist not found" >&2; exit 1; }

bash "$root/tools/wsl/attach.sh"

echo "== mkdir $hal"
python3 "$root/tools/usb-ring.py" mkdir "$hal"

echo "== wfile Info.plist"
python3 "$root/tools/usb-ring.py" wfile "$hal/Info.plist" "$dir/Info.plist"

# Remove the binary first: written over in place, the kernel keeps the code
# signature it read for the old file and every page of the new one fails it.
python3 "$root/tools/usb-ring.py" del "$hal/MondrianAudio" > /dev/null 2>&1 || true

echo "== wfile MondrianAudio"
python3 "$root/tools/usb-ring.py" wfile "$hal/MondrianAudio" "$dir/MondrianAudio"

echo "== ls"
python3 "$root/tools/usb-ring.py" ls "$hal" || true

echo "== restart mediaserverd so the HAL loader reads the directory"
python3 "$root/tools/usb-ring.py" kill mediaserverd || true
sleep 3
echo "installed; look for 'mondrian hal:' in the console ring"
