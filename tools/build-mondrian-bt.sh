#!/bin/bash
# Build the diagnostic dylib 0389 injects into bluetoothd.
#
# Same two branches as build-mondrian-ui-hook.sh: xcrun and codesign on macOS,
# the WSL clang and ld64.lld on Linux. Nothing here is signed on either side -
# the kernel carries this dylib to /private/var/vm through its own path, and
# AMFI is not what loads it.
set -euo pipefail

out=${1:?usage: build-mondrian-bt.sh OUTPUT.dylib}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$(dirname "$out")"

if command -v xcrun >/dev/null 2>&1 &&
    sdk=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) &&
    [ -d "$sdk" ] && [ -n "$(ls -A "$sdk" 2>/dev/null)" ]; then
	xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
		-dynamiclib -Os -fno-common -fvisibility=hidden \
		-install_name /private/var/vm/mondrian-bt.dylib \
		-o "$out" "$root/tools/mondrian-bt.c"
else
	sdk=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
	ld=${LD64_LLD:-/usr/lib/llvm-18/bin/ld64.lld}
	clang -target arm64-apple-ios16.0 -isysroot "$sdk" -c -Os -fno-common \
		-fvisibility=hidden "$root/tools/mondrian-bt.c" -o "$out.o"
	"$ld" -arch arm64 -platform_version ios 16.0 16.0 -dylib \
		-install_name /private/var/vm/mondrian-bt.dylib \
		-syslibroot "$sdk" -L"$sdk/usr/lib" -undefined dynamic_lookup \
		-o "$out" "$out.o"
	rm -f "$out.o"
fi
file "$out"
