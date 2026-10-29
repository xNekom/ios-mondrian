#!/bin/bash
# Build and ad-hoc sign the Mesa-on-the-GPU smoke test.
#
#   tools/build-mondrian-mesa-test.sh /tmp/mondrian-mesa-test.dylib
#
# It resolves libOSMesa at run time, so it builds against the SDK alone. Look
# for "MONDRIAN MESA TEST: PASSED (the GPU drew it)" in the kernel log; a
# "SOFTWARE" verdict means Mesa came up but not on the GPU.
set -euo pipefail

out=${1:?usage: build-mondrian-mesa-test.sh OUTPUT.dylib}
root=$(cd "$(dirname "$0")/.." && pwd)
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p "$(dirname "$out")"
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
	-dynamiclib -Os -fno-common -fvisibility=hidden \
	-install_name /usr/libexec/mondrian-mesa-test.dylib \
	-o "$out" "$root/tools/mondrian-mesa-test.c" -framework IOKit \
	-framework CoreFoundation
codesign --force --sign - --timestamp=none "$out"
codesign --verify --strict "$out"
file "$out"
