#!/bin/bash
# Build the Mondrian speaker HAL driver as an iOS bundle.
#
#   tools/build-mondrian-hal.sh out/MondrianAudio.driver
#
# iOS ships HAL drivers as flat bundles (AppleUSBAudio.driver holds its binary
# and Info.plist directly), so the result is a directory holding `Info.plist`
# and the executable named by CFBundleExecutable. Install it into
# /System/Library/Audio/Plug-Ins/HAL/ on the device; see docs/MONDIAN_AUDIO.md.
set -euo pipefail

out=${1:?usage: build-mondrian-hal.sh OUT.driver}
root=$(cd "$(dirname "$0")/.." && pwd)
src=$root/tools/mondrian-hal/mondrian-audio-driver.c
sdk=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
ld=${LD64_LLD:-/usr/lib/llvm-18/bin/ld64.lld}

[ -f "$src" ] || { echo "error: $src not found" >&2; exit 1; }
[ -d "$sdk" ] || { echo "error: iOS SDK not found at $sdk" >&2; exit 1; }

mkdir -p "$out/Contents" 2>/dev/null || true
rm -rf "$out"
mkdir -p "$out"
cp "$root/tools/mondrian-hal/Info.plist" "$out/Info.plist"

obj=$(mktemp /tmp/mondrian-hal.XXXXXX.o)
trap 'rm -f "$obj"' EXIT

clang -target arm64-apple-ios16.0 -isysroot "$sdk" -c -Os -fno-common \
	-fvisibility=hidden -Wall -Wextra -Wno-unused-parameter \
	"$src" -o "$obj"
"$ld" -arch arm64 -platform_version ios 16.0 16.0 -bundle -adhoc_codesign \
	-install_name /System/Library/Audio/Plug-Ins/HAL/MondrianAudio.driver/MondrianAudio \
	-syslibroot "$sdk" -F"$sdk/System/Library/Frameworks" \
	-framework CoreFoundation \
	-L"$sdk/usr/lib" -lSystem \
	-undefined dynamic_lookup \
	-o "$out/MondrianAudio" "$obj"

chmod 0755 "$out/MondrianAudio"
echo "built $out"
ls -l "$out"
