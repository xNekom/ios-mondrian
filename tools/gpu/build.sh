#!/bin/bash
# Build the two dylibs of the CoreAnimation/OpenGL ES path (see docs/COREANIMATION_GLES.md):
#
#   tools/gpu/build.sh OUTDIR [MESA_BUILD_DIR]
#
#     OUTDIR/mondrian-gl.dylib       eagl.c + gl_osmesa.c + the generated eagl_gen.h; goes to
#                                    /usr/libexec/mondrian-gl.dylib on the root
#     OUTDIR/mondrian-inject.dylib   mondrian_inject.c; goes to /usr/libexec/mondrian-inject.dylib
#
# MESA_BUILD_DIR is the Mesa build tree the mesa agent's tools/mk-mesa-ios.sh makes
# (build-<drivers>/src/gallium/targets/osmesa); it supplies libOSMesa.8.dylib. The install name of
# that library is @rpath/libOSMesa.8.dylib, hence the rpath below: on the phone it is
# /usr/lib/libOSMesa.8.dylib (the meson prefix /usr).
#
# Both are ad-hoc signed. Nothing here runs on hardware: it compiles for iOS 16 arm64.
set -euo pipefail

out=${1:?usage: tools/gpu/build.sh OUTDIR [MESA_BUILD_DIR]}
mesa=${2:-$(cd "$(dirname "$0")/../.." && pwd)/out/mesa/build-softpipe-freedreno/src/gallium/targets/osmesa}
here=$(cd "$(dirname "$0")" && pwd)
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
build=$(mktemp -d "${TMPDIR:-/tmp}/mondrian-gl.XXXXXX")
trap 'rm -rf "$build"' EXIT

mkdir -p "$out"

# eagl.c includes this file twice; it is generated, never committed.
python3 "$here/mkeagl.py" -o "$build/eagl_gen.h"

common=(-target arm64-apple-ios16.0 -isysroot "$sdk" -dynamiclib -Os -fno-common
	-fvisibility=hidden -I "$here" -I "$build")

xcrun --sdk iphoneos clang "${common[@]}" \
	-install_name /usr/libexec/mondrian-gl.dylib \
	-o "$out/mondrian-gl.dylib" \
	"$here/eagl.c" "$here/gl_osmesa.c" \
	-L "$mesa" -lOSMesa.8 -Wl,-rpath,/usr/lib \
	-framework IOKit -framework IOSurface -framework CoreFoundation

xcrun --sdk iphoneos clang "${common[@]}" \
	-install_name /usr/libexec/mondrian-inject.dylib \
	-o "$out/mondrian-inject.dylib" \
	"$here/mondrian_inject.c" \
	-framework IOKit -framework CoreFoundation

for dylib in "$out/mondrian-gl.dylib" "$out/mondrian-inject.dylib"; do
	codesign --force --sign - --timestamp=none "$dylib"
	codesign --verify --strict "$dylib"
	file "$dylib"
done
