#!/usr/bin/env bash
# Install the built iOS userland dylibs into a root image, from Windows/WSL.
#
#   tools/wsl/install-dylibs.sh ROOT.img \
#       [--gl out/gpu/mondrian-gl.dylib] [--inject out/gpu/mondrian-inject.dylib] \
#       [--ui-hook /tmp/mondrian-ui-hook.dylib] [--gpu-test /tmp/mondrian-gpu-test.dylib] \
#       [--mesa out/mesa/stage]
#
# The macOS path is tools/install-userland.sh (hdiutil + ios-root-tweaks.py, which
# also rewrites plists). This one only copies files, so it needs no mounted
# volume: tools/wsl/hfs-tool.sh does the write inside a helper VM, and it is
# meant for iterating on the dylibs once the rest of the bring-up is in place.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
image=${1:?usage: install-dylibs.sh ROOT.img [--gl DYLIB] [--inject DYLIB] [--ui-hook DYLIB] [--gpu-test DYLIB] [--mesa STAGE]}
shift
[ -f "$image" ] || { echo "error: $image not found" >&2; exit 1; }

stage=$(mktemp -d "${TMPDIR:-/tmp}/ios-dylibs.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/usr/libexec" "$stage/usr/lib"

n=0
while [ $# -gt 0 ]; do
	option=$1
	value=${2:-}
	[ -n "$value" ] || { echo "error: $option needs a value" >&2; exit 1; }
	case "$option" in
	--gl) [ -f "$value" ] || { echo "error: no $value" >&2; exit 1; }
		cp "$value" "$stage/usr/libexec/mondrian-gl.dylib" ;;
	--inject) [ -f "$value" ] || { echo "error: no $value" >&2; exit 1; }
		cp "$value" "$stage/usr/libexec/mondrian-inject.dylib" ;;
	--ui-hook) [ -f "$value" ] || { echo "error: no $value" >&2; exit 1; }
		cp "$value" "$stage/usr/libexec/mondrian-ui-hook.dylib" ;;
	--gpu-test) [ -f "$value" ] || { echo "error: no $value" >&2; exit 1; }
		cp "$value" "$stage/usr/libexec/mondrian-gpu-test.dylib" ;;
	--mesa) [ -f "$value/libOSMesa.8.dylib" ] || { echo "error: no $value/libOSMesa.8.dylib" >&2; exit 1; }
		cp "$value/libOSMesa.8.dylib" "$stage/usr/lib/libOSMesa.8.dylib" ;;
	*) echo "error: unknown option $option" >&2; exit 1 ;;
	esac
	n=$((n + 1))
	shift 2
done
[ "$n" -gt 0 ] || { echo "error: nothing to install" >&2; exit 1; }

echo "== staging $n librar(y/ies):"
find "$stage" -type f -printf '   %P %s bytes\n'
"$here/hfs-tool.sh" put "$image" / "$stage"
echo "== installed into $image"
