#!/bin/bash
# Build the Settings-app probe dylib (tools/mondrian-probe.m).
#
#   tools/build-mondrian-probe.sh OUTPUT.dylib
#
# Same toolchain as tools/build-mondrian-ui-hook.sh: on Linux the wrappers in
# ~/.local/ios-tc/bin provide xcrun and an ad-hoc codesign (the port has no AMFI
# policy, so nothing checks the signature), on the Mac the SDK does.
set -euo pipefail

out=${1:?usage: build-mondrian-probe.sh OUTPUT.dylib}
root=$(cd "$(dirname "$0")/.." && pwd)
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p "$(dirname "$out")"
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
	-dynamiclib -Os -fno-common -fblocks -fvisibility=hidden \
	-install_name /private/var/vm/mondrian-probe.dylib \
	-o "$out" "$root/tools/mondrian-probe.m" \
	-Wl,-undefined,dynamic_lookup -framework Foundation
codesign --force --sign - --timestamp=none "$out"
codesign --verify --strict "$out"
file "$out"
