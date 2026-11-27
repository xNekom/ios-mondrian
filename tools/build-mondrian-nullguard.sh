#!/bin/bash
# Build MondrianNullGuard.dylib for iOS arm64, ad-hoc signed.
set -euo pipefail
sdk=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
ld=${LD64_LLD:-/usr/lib/llvm-18/bin/ld64.lld}
src=/mnt/c/Users/Pedro/Documents/GitHub/ios-mondrian/tools/mondrian-hal/nullguard.c
out=/root/mondrian-hal/MondrianNullGuard.dylib
obj=$(mktemp /tmp/nullguard.XXXXXX.o)
trap 'rm -f "$obj"' EXIT
clang -target arm64-apple-ios16.0 -isysroot "$sdk" -c -Os -Wall \
	"$src" -o "$obj"
"$ld" -arch arm64 -platform_version ios 16.0 16.0 -dylib -adhoc_codesign \
	-install_name /private/var/vm/MondrianNullGuard.dylib \
	-syslibroot "$sdk" -L"$sdk/usr/lib" -lSystem \
	-undefined dynamic_lookup -o "$out" "$obj"
chmod 0755 "$out"
echo "built $out"
ls -l "$out"
