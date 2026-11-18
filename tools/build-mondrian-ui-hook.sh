#!/bin/bash
# Build and ad-hoc sign the opt-in iOS 16 arm64 UI diagnostic hook.
#
# On macOS this uses xcrun and codesign. On Linux there is no xcrun and no
# codesign, so it uses the clang and ld64.lld the WSL toolchain installs and
# skips signing: the kernel loads the hook from /private/var/vm through its own
# blob path, not through AMFI. Without this branch a hook change silently needs
# a hand-written command, and the kernel build keeps embedding the old dylib.
set -euo pipefail

out=${1:?usage: build-mondrian-ui-hook.sh OUTPUT.dylib}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$(dirname "$out")"

# `command -v xcrun` is not enough: a stub on PATH made the script take this
# branch, `--show-sdk-path` answered the literal "iphoneos", and the build died
# on 'objc/objc.h' instead of falling through to the Linux toolchain.
if command -v xcrun >/dev/null 2>&1 &&
    sdk=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) &&
    [ -d "$sdk" ] && [ -n "$(ls -A "$sdk" 2>/dev/null)" ]; then
	xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
		-dynamiclib -Os -fno-common -fvisibility=hidden \
		-install_name /usr/libexec/mondrian-ui-hook.dylib \
		-o "$out" "$root/tools/mondrian-ui-hook.m" -lobjc -Wl,-undefined,dynamic_lookup -framework CoreFoundation -framework Foundation -framework QuartzCore -framework CoreGraphics -framework IOKit
	codesign --force --sign - --timestamp=none "$out"
	codesign --verify --strict "$out"
else
	sdk=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
	ld=${LD64_LLD:-/usr/lib/llvm-18/bin/ld64.lld}
	clang -target arm64-apple-ios16.0 -isysroot "$sdk" -c -Os -fno-common \
		-fvisibility=hidden "$root/tools/mondrian-ui-hook.m" -o "$out.o"
	"$ld" -arch arm64 -platform_version ios 16.0 16.0 -dylib \
		-install_name /usr/libexec/mondrian-ui-hook.dylib \
		-syslibroot "$sdk" -F"$sdk/System/Library/Frameworks" \
		-framework CoreFoundation -framework Foundation -framework QuartzCore \
		-framework CoreGraphics -framework IOKit \
		-L"$sdk/usr/lib" -lobjc -undefined dynamic_lookup \
		-o "$out" "$out.o"
	rm -f "$out.o"
fi
file "$out"
