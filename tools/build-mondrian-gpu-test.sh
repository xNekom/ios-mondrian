#!/bin/bash
# Build and ad-hoc sign the MondrianGPU smoke test dylib.
#
#   tools/build-mondrian-gpu-test.sh /tmp/mondrian-gpu-test.dylib
#
# It logs to stderr and /dev/console, so its lines appear in the kernel ring
# log next to the driver's own. Load it in a process that runs once the GPU
# is up (mondrian-ui-hook.dylib dlopens it) and look for
# "MONDRIAN GPU TEST: PASSED".
set -euo pipefail

out=${1:?usage: build-mondrian-gpu-test.sh OUTPUT.dylib}
root=$(cd "$(dirname "$0")/.." && pwd)
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p "$(dirname "$out")"
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
	-dynamiclib -Os -fno-common -fvisibility=hidden \
	-install_name /usr/libexec/mondrian-gpu-test.dylib \
	-o "$out" "$root/tools/mondrian-gpu-test.c" -framework IOKit \
	-framework CoreFoundation
codesign --force --sign - --timestamp=none "$out"
codesign --verify --strict "$out"
file "$out"
