#!/bin/bash
# Build and ad-hoc sign the MondrianGPU smoke test dylib.
#
#   tools/build-mondrian-gpu-test.sh /tmp/mondrian-gpu-test.dylib
#
# It logs to stderr and /dev/console, so its lines appear in the kernel ring
# log next to the driver's own. Load it in a process that runs once the GPU
# is up (mondrian-ui-hook.dylib dlopens it) and look for
# "MONDRIAN GPU TEST: PASSED".
set -euo pipefail

out=${1:?usage: build-mondrian-gpu-test.sh OUTPUT.dylib}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$(dirname "$out")"

# Linux has no xcrun or codesign: use clang and the ld64.lld the WSL toolchain
# installs, against the same iPhoneOS SDK the UI hook uses. The dylib is loaded
# from the iOS root, not through AMFI, so no signature is needed.
if command -v xcrun >/dev/null 2>&1 &&
    sdk=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) &&
    [ -d "$sdk" ] && [ -n "$(ls -A "$sdk" 2>/dev/null)" ]; then
	xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
		-dynamiclib -Os -fno-common -fvisibility=hidden \
		-install_name /usr/libexec/mondrian-gpu-test.dylib \
		-o "$out" "$root/tools/mondrian-gpu-test.c" -framework IOKit \
		-framework CoreFoundation
	codesign --force --sign - --timestamp=none "$out"
	codesign --verify --strict "$out"
else
	sdk=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
	ld=${LD64_LLD:-/usr/lib/llvm-18/bin/ld64.lld}
	clang -target arm64-apple-ios16.0 -isysroot "$sdk" -c -Os -fno-common \
		-fvisibility=hidden "$root/tools/mondrian-gpu-test.c" -o "$out.o"
	"$ld" -arch arm64 -platform_version ios 16.0 16.0 -dylib \
		-install_name /usr/libexec/mondrian-gpu-test.dylib \
		-syslibroot "$sdk" -F"$sdk/System/Library/Frameworks" \
		-framework IOKit -framework CoreFoundation \
		-undefined dynamic_lookup -o "$out" "$out.o"
	rm -f "$out.o"
fi
file "$out"
