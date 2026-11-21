#!/bin/bash
# Build and ad-hoc sign the picture bridge an app receives (0402).
#
# The bridge is deliberately not part of tools/mondrian-ui-hook.m: that dylib
# carries the services' dyld interposers, and an app needs none of them. This
# file only turns a layer's CGImage into a surface (see
# tools/mondrian-layer-bridge.m).
#
# On macOS this uses xcrun and codesign. On Linux it uses the clang and ld64.lld
# the WSL toolchain installs and skips signing: the kernel loads the dylib from
# /private/var/vm through its blob path, not through AMFI.
#
# The file has to be on the phone once: the kernel injects
# /private/var/vm/mondrian-layer-bridge.dylib into every app in /Applications,
# and a boot without it leaves apps clean (the ring says so once, per app, as
# `MONDRIAN HOOK: ... stays clean, no bridge in /private/var/vm`). Deliver it with
#   tools/usb-ring.py wfile /private/var/vm/mondrian-layer-bridge.dylib OUT
# and it stays in userdata across boots (glblob=1 carries the hook, not this).
# 0402 also accepts /usr/libexec/mondrian-layer-bridge.dylib, so a root image
# that carries the dylib needs no delivery at all.
#
# A/B: /private/var/vm/mondrian-layercsurf-off on the phone keeps every CGImage
# as it is (bridge off, renderer untouched) and needs no rebuild.
set -euo pipefail

out=${1:-out/gpu/mondrian-layer-bridge.dylib}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$(dirname "$out")"

if command -v xcrun >/dev/null 2>&1 &&
    sdk=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) &&
    [ -d "$sdk" ] && [ -n "$(ls -A "$sdk" 2>/dev/null)" ]; then
	xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
		-dynamiclib -Os -fno-common -fvisibility=hidden \
		-install_name /usr/libexec/mondrian-layer-bridge.dylib \
		-o "$out" "$root/tools/mondrian-layer-bridge.m" -lobjc \
		-Wl,-undefined,dynamic_lookup -framework CoreFoundation \
		-framework CoreGraphics -framework IOSurface
	codesign --force --sign - --timestamp=none "$out"
	codesign --verify --strict "$out"
else
	sdk=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
	ld=${LD64_LLD:-/usr/lib/llvm-18/bin/ld64.lld}
	clang -target arm64-apple-ios16.0 -isysroot "$sdk" -c -Os -fno-common \
		-fvisibility=hidden "$root/tools/mondrian-layer-bridge.m" -o "$out.o"
	"$ld" -arch arm64 -platform_version ios 16.0 16.0 -dylib \
		-install_name /usr/libexec/mondrian-layer-bridge.dylib \
		-syslibroot "$sdk" -F"$sdk/System/Library/Frameworks" \
		-framework CoreFoundation -framework CoreGraphics \
		-framework IOSurface \
		-L"$sdk/usr/lib" -lobjc -undefined dynamic_lookup \
		-o "$out" "$out.o"
	rm -f "$out.o"
fi
file "$out"
