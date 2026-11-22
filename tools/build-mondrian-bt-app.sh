#!/bin/bash
# Build the Settings-only Bluetooth XPC tap (tools/mondrian-bt-app.m).
#
#   tools/build-mondrian-bt-app.sh [out/gpu/mondrian-bt-app.dylib]
#
# Delivered to /private/var/vm/mondrian-bt-app.dylib; the layer bridge, which
# every app receives, loads it only when the program name is "Preferences".
# Overwrite the installed file with anything that is not a Mach-O to switch it
# off: the dlopen then fails and Settings keeps its normal XPC.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-out/gpu/mondrian-bt-app.dylib}
mkdir -p "$(dirname "$out")"

if command -v xcrun >/dev/null 2>&1 &&
    sdk=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) &&
    [ -d "$sdk" ] && [ -n "$(ls -A "$sdk" 2>/dev/null)" ]; then
	xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
		-dynamiclib -Os -fno-common -fvisibility=hidden \
		-install_name /private/var/vm/mondrian-bt-app.dylib \
		-o "$out" "$root/tools/mondrian-bt-app.m" \
		-Wl,-undefined,dynamic_lookup
	codesign --force --sign - --timestamp=none "$out"
else
	sdk=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
	ld=${LD64_LLD:-/usr/lib/llvm-18/bin/ld64.lld}
	clang -target arm64-apple-ios16.0 -isysroot "$sdk" -c -Os -fno-common \
		-fvisibility=hidden "$root/tools/mondrian-bt-app.m" -o "$out.o"
	"$ld" -arch arm64 -platform_version ios 16.0 16.0 -dylib \
		-install_name /private/var/vm/mondrian-bt-app.dylib \
		-syslibroot "$sdk" -L"$sdk/usr/lib" -lobjc \
		-undefined dynamic_lookup -o "$out" "$out.o"
	rm -f "$out.o"
fi
file "$out"
