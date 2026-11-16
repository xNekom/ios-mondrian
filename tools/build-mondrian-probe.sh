#!/bin/bash
# Build the bring-up probe dylib (tools/mondrian-probe.m).
#
#   tools/build-mondrian-probe.sh OUTPUT.dylib
#
# On macOS this uses xcrun and codesign. On Linux there is no xcrun and no
# codesign, so it uses the clang and ld64.lld the WSL toolchain installs and
# skips signing: the kernel loads the file from /private/var/vm through its own
# blob path, not through AMFI. Without this branch a probe change silently
# needs a hand-written command and the kernel keeps embedding the old dylib.
#
# CoreAccessories is linked on purpose: the probe interposes one of its
# functions, so the framework has to be loaded when the interpose table is
# bound. It is the only framework the probe links.
set -euo pipefail

out=${1:?usage: build-mondrian-probe.sh OUTPUT.dylib}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$(dirname "$out")"

if command -v xcrun >/dev/null 2>&1; then
	sdk=$(xcrun --sdk iphoneos --show-sdk-path)
	xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
		-dynamiclib -Os -fno-common -fvisibility=hidden \
		-install_name /private/var/vm/mondrian-probe.dylib \
		-F"$sdk/System/Library/PrivateFrameworks" \
		-o "$out" "$root/tools/mondrian-probe.m" \
		-Wl,-undefined,dynamic_lookup -framework Foundation \
		-framework CoreAccessories
	codesign --force --sign - --timestamp=none "$out"
	codesign --verify --strict "$out"
else
	sdk=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
	ld=${LD64_LLD:-/usr/lib/llvm-18/bin/ld64.lld}
	clang -target arm64-apple-ios16.0 -isysroot "$sdk" -c -Os -fno-common \
		-fvisibility=hidden "$root/tools/mondrian-probe.m" -o "$out.o"
	"$ld" -arch arm64 -platform_version ios 16.0 16.0 -dylib \
		-install_name /private/var/vm/mondrian-probe.dylib \
		-syslibroot "$sdk" -F"$sdk/System/Library/Frameworks" \
		-F"$sdk/System/Library/PrivateFrameworks" \
		-framework Foundation -framework CoreAccessories \
		-L"$sdk/usr/lib" -undefined dynamic_lookup \
		-o "$out" "$out.o"
	rm -f "$out.o"
fi
file "$out"
