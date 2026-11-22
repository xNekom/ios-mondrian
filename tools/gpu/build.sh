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
sdk=${MONDRIAN_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}
if [ ! -f "$sdk/usr/include/stdlib.h" ]; then
	for sdkdir in "$HOME"/sdks/iPhoneOS*.sdk; do
		if [ -f "$sdkdir/usr/include/stdlib.h" ]; then
			sdk="$sdkdir"
			break
		fi
	done
fi
build=$(mktemp -d "${TMPDIR:-/tmp}/mondrian-gl.XXXXXX")
trap 'rm -rf "$build"' EXIT

mkdir -p "$out"

# eagl.c includes this file twice; it is generated, never committed.
# `xcrun --show-sdk-path` can answer with a macOS or a stripped SDK that has no
# OpenGLES headers (measured 2026-11-22); the iPhoneOS SDK in ~/sdks does.
glheaders=${MONDRIAN_GL_HEADERS:-}
if [ -z "$glheaders" ]; then
	for sdkdir in "$HOME"/sdks/iPhoneOS*.sdk; do
		if [ -d "$sdkdir/System/Library/Frameworks/OpenGLES.framework/Headers" ]; then
			glheaders="$sdkdir/System/Library/Frameworks/OpenGLES.framework/Headers"
			break
		fi
	done
fi
if [ -n "$glheaders" ]; then
	python3 "$here/mkeagl.py" -o "$build/eagl_gen.h" --headers "$glheaders"
else
	python3 "$here/mkeagl.py" -o "$build/eagl_gen.h"
fi

common=(-target arm64-apple-ios16.0 -isysroot "$sdk" -dynamiclib -Os -fno-common
	-fvisibility=hidden -I "$here" -I "$build")

# The Mach-O link needs ld64.lld; the distro's clang picks GNU ld otherwise and
# answers "unrecognised emulation mode: llvm" (measured 2026-11-22). The
# versioned binary is there without an unversioned name, so name it explicitly.
ldflag=()
for candidate in /usr/bin/ld64.lld "$(command -v ld64.lld)" /usr/bin/ld64.lld-*; do
	if [ -x "$candidate" ]; then
		# The distro clang does not hand the Darwin flags to a linker named by
		# an absolute path, so they are given here.
		ldflag=(-fuse-ld="$candidate" -Wl,-arch,arm64
			-Wl,-platform_version,ios,16.0,16.0)
		break
	fi
done

xcrun --sdk iphoneos clang "${common[@]}" "${ldflag[@]}" \
	-install_name /usr/libexec/mondrian-gl.dylib \
	-o "$out/mondrian-gl.dylib" \
	"$here/eagl.c" "$here/gl_osmesa.c" \
	-L "$mesa" -lOSMesa.8 -Wl,-rpath,/usr/lib \
	-framework IOKit -framework IOSurface -framework CoreFoundation

xcrun --sdk iphoneos clang "${common[@]}" "${ldflag[@]}" \
	-install_name /usr/libexec/mondrian-inject.dylib \
	-o "$out/mondrian-inject.dylib" \
	"$here/mondrian_inject.c" \
	-framework IOKit -framework CoreFoundation

for dylib in "$out/mondrian-gl.dylib" "$out/mondrian-inject.dylib"; do
	codesign --force --sign - --timestamp=none "$dylib"
	codesign --verify --strict "$dylib"
	file "$dylib"
done
