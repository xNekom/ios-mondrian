#!/bin/bash
# Build and ad-hoc sign the opt-in iOS 16 arm64 UI diagnostic hook.
set -euo pipefail

out=${1:?usage: build-mondrian-ui-hook.sh OUTPUT.dylib}
root=$(cd "$(dirname "$0")/.." && pwd)
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p "$(dirname "$out")"
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
	-dynamiclib -Os -fno-common -fvisibility=hidden \
	-install_name /usr/libexec/mondrian-ui-hook.dylib \
	-o "$out" "$root/tools/mondrian-ui-hook.m" -lobjc -framework CoreFoundation
codesign --force --sign - --timestamp=none "$out"
codesign --verify --strict "$out"
file "$out"
