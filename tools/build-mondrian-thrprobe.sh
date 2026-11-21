#!/bin/bash
# Build the thread probe dylib (tools/mondrian-thrprobe.m).
#
#   tools/build-mondrian-thrprobe.sh OUT/gpu/mondrian-thrprobe.dylib
#
# Same toolchain as tools/build-mondrian-probe.sh, and the same install name:
# patch 0306 injects /private/var/vm/mondrian-probe.dylib into the process named
# by mondrian_probe_proc, so this file is deployed over that path.
#
# It links no framework on purpose (see the source): a daemon that is already
# suspected of an XPC deadlock is not the place to load Foundation.
set -euo pipefail

out=${1:?usage: build-mondrian-thrprobe.sh OUTPUT.dylib}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$(dirname "$out")"

sdk=""
if command -v xcrun >/dev/null 2>&1; then
	sdk=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
fi
# The WSL toolchain also ships an `xcrun` that answers "iphoneos" and has no
# sysroot, so the macOS branch needs a real SDK, not just the command.
if [ -n "$sdk" ] && [ -d "$sdk/usr/include" ] &&
	command -v codesign >/dev/null 2>&1; then
	xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
		-dynamiclib -Os -fno-common -fvisibility=hidden \
		-install_name /private/var/vm/mondrian-probe.dylib \
		-o "$out" "$root/tools/mondrian-thrprobe.m"
else
	sdk=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
	ld=${LD64_LLD:-/usr/lib/llvm-18/bin/ld64.lld}
	clang -target arm64-apple-ios16.0 -isysroot "$sdk" -c -Os -fno-common \
		-fvisibility=hidden "$root/tools/mondrian-thrprobe.m" -o "$out.o"
	"$ld" -arch arm64 -platform_version ios 16.0 16.0 -dylib \
		-install_name /private/var/vm/mondrian-probe.dylib \
		-syslibroot "$sdk" -L"$sdk/usr/lib" -undefined dynamic_lookup \
		-o "$out" "$out.o"
	rm -f "$out.o"
fi
file "$out"
