#!/bin/bash
# Install a rebuilt mondrian-gpu-test.dylib into an iOS root image.
#
#   tools/build-mondrian-gpu-test.sh /tmp/mondrian-gpu-test.dylib
#   sudo tools/install-gpu-test.sh /private/tmp/ios16/ios16-root.img \
#       /tmp/mondrian-gpu-test.dylib
#
# The image is HFS+ and is flashed to the userdata partition afterwards with
# tools/flash-root.sh. Mounting and writing needs root: the root image is owned
# by root, and the files inside it are owned by root/mobile.
#
# The tweaks script is idempotent, so the rest of the bring-up changes are
# applied (or re-applied) in the same pass. The dylib runs only if
# /usr/libexec/mondrian-ui-hook.dylib is in the image too: the UI hook dlopens
# it, and the verdict is a "MONDRIAN GPU TEST:" line in the kernel ring log.
set -euo pipefail

image=${1:?usage: install-gpu-test.sh ROOT.img DYLIB}
dylib=${2:?usage: install-gpu-test.sh ROOT.img DYLIB}

[ "$(id -u)" = 0 ] || { echo "error: run this with sudo" >&2; exit 1; }
[ -f "$image" ] || { echo "error: $image not found" >&2; exit 1; }
[ -f "$dylib" ] || { echo "error: $dylib not found" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)

# The image is normally attached read-only so the dyld shared cache can be
# read from it; detach that first.
hdiutil detach /Volumes/iOSRO >/dev/null 2>&1 || true

echo "== attaching $image (read/write)"
attach=$(hdiutil attach -readwrite -nobrowse "$image")
volume=$(printf '%s\n' "$attach" | awk '/\/Volumes\// { sub(/.*\/Volumes\//, "/Volumes/"); print; exit }')
[ -n "$volume" ] || { echo "error: the image did not mount" >&2; exit 1; }
echo "== mounted at $volume"

echo "== installing $dylib"
python3 "$here/ios-root-tweaks.py" "$volume" --gpu-test "$dylib"

sync
echo "== detaching"
hdiutil detach "$volume" >/dev/null
echo "== done"
