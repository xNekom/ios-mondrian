#!/bin/bash
# Install the GPU userland into an iOS root image in one pass.
#
#   tools/build-mondrian-ui-hook.sh  /tmp/mondrian-ui-hook.dylib
#   tools/build-mondrian-gpu-test.sh /tmp/mondrian-gpu-test.dylib
#   tools/mk-mesa-ios.sh                       # stages out/mesa/stage
#   sudo tools/install-userland.sh /private/tmp/ios16/ios16-root.img \
#       --ui-hook  /tmp/mondrian-ui-hook.dylib \
#       --gpu-test /tmp/mondrian-gpu-test.dylib \
#       --mesa     out/mesa/stage
#   python3 tools/mk-simg.py IMAGE IMAGE.simg && tools/flash-root.sh IMAGE.simg
#
# Every option is optional and is passed straight to tools/ios-root-tweaks.py,
# which also applies the rest of the bring-up changes (it is idempotent).
# What each one lands:
#
#   --ui-hook   /usr/libexec/mondrian-ui-hook.dylib, the dylib the kernel
#               injects into containermanagerd/backboardd/SpringBoard
#               (boot argument mondrian_ui_hook)
#   --gpu-test  /usr/libexec/mondrian-gpu-test.dylib, dlopened by the UI hook;
#               its verdict is a "MONDRIAN GPU TEST:" line in the ring log
#   --mesa      /usr/lib/libOSMesa.8.dylib from the staged Mesa tree
set -euo pipefail

image=${1:?usage: install-userland.sh ROOT.img [--ui-hook DYLIB] [--gpu-test DYLIB] [--mesa STAGE_DIR]}
shift

[ -f "$image" ] || { echo "error: $image not found" >&2; exit 1; }
[ "$#" -gt 0 ] || { echo "error: nothing to install" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)

# Fail before touching the image if any source is missing or any option is
# malformed. Options come in pairs.
scan=("$@")
index=0
while [ "$index" -lt "${#scan[@]}" ]; do
	option=${scan[$index]}
	if [ $((index + 1)) -ge "${#scan[@]}" ]; then
		echo "error: $option needs a value" >&2
		exit 1
	fi
	value=${scan[$((index + 1))]}
	case "$option" in
	--ui-hook|--gpu-test)
		[ -f "$value" ] || { echo "error: $option not found: $value" >&2; exit 1; }
		;;
	--mesa)
		[ -f "$value/libOSMesa.8.dylib" ] || {
			echo "error: libOSMesa.8.dylib not in $value" >&2; exit 1; }
		;;
	*)
		echo "error: unknown option $option" >&2
		exit 1
		;;
	esac
	index=$((index + 2))
done

[ "$(id -u)" = 0 ] || { echo "error: run this with sudo" >&2; exit 1; }

# The image is normally attached read-only, at /Volumes/iOSRoot or under a
# numbered name, so the dyld shared cache can be read from it; hdiutil refuses
# to attach an image that is already attached. Find the device by image path:
# the volume name is not part of the contract.
detach_image() {
	device=$(hdiutil info | awk -v image="$1" '
		$1 == "image-path" { current = $3 }
		$1 ~ /^\/dev\/disk/ && current == image { print $1; exit }')
	if [ -n "$device" ]; then
		hdiutil detach "$device" >/dev/null 2>&1 || true
	fi
}

detach_image "$image"

echo "== attaching $image (read/write)"
attach=$(hdiutil attach -readwrite -nobrowse "$image")
volume=$(printf '%s\n' "$attach" | awk '/\/Volumes\// { sub(/.*\/Volumes\//, "/Volumes/"); print; exit }')
[ -n "$volume" ] || { echo "error: the image did not mount" >&2; exit 1; }
echo "== mounted at $volume"

echo "== installing"
python3 "$here/ios-root-tweaks.py" "$volume" "$@"

sync
echo "== detaching"
hdiutil detach "$volume" >/dev/null
echo "== done"
