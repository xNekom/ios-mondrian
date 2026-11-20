#!/bin/bash
# Build the dylib 0393 injects into MobileSafari.
#
# Same two branches as build-mondrian-bt.sh: xcrun and codesign on macOS, the
# WSL clang and ld64.lld on Linux. Nothing is signed on either side; the kernel
# carries the file to /private/var/vm and dyld loads it through
# DYLD_INSERT_LIBRARIES, which 0108's AMFI policy allows.
set -euo pipefail

out=${1:?usage: build-mondrian-safari.sh OUTPUT.dylib}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$(dirname "$out")"

if command -v xcrun >/dev/null 2>&1 &&
    sdk=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) &&
    [ -d "$sdk" ] && [ -n "$(ls -A "$sdk" 2>/dev/null)" ]; then
	xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
		-dynamiclib -Os -fno-common -fvisibility=hidden \
		-framework Foundation \
		-install_name /private/var/vm/mondrian-safari.dylib \
		-o "$out" "$root/tools/mondrian-safari.m"
else
	sdk=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
	ld=${LD64_LLD:-/usr/lib/llvm-18/bin/ld64.lld}
	clang -target arm64-apple-ios16.0 -isysroot "$sdk" -c -Os -fno-common \
		-fvisibility=hidden "$root/tools/mondrian-safari.m" -o "$out.o"
	"$ld" -arch arm64 -platform_version ios 16.0 16.0 -dylib \
		-install_name /private/var/vm/mondrian-safari.dylib \
		-syslibroot "$sdk" -L"$sdk/usr/lib" -undefined dynamic_lookup \
		-o "$out" "$out.o"
	rm -f "$out.o"
fi
file "$out"
