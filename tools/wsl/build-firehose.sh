#!/usr/bin/env bash
# Build libfirehose_kernel.a on Linux, without xcodebuild.
#
# Called by tools/wsl/build-kernel.sh with LD/FAKEROOT/XNU/OUT set. The Xcode
# target compiles exactly one file, libdispatch's src/firehose/firehose_buffer.c,
# which needs two MIG outputs: firehose.h (the kernel is a client of
# firehose.defs) and firehose_replyServer.h (the kernel serves firehose_reply).
# Everything it includes comes from the fakeroot that installhdrs filled.
#
# xnu 8796 ships the firehose private headers (libkern/firehose/*.h) itself,
# which is why they can be copied instead of taken from an SDK.
set -euo pipefail

: "${LD:?}" "${FAKEROOT:?}" "${XNU:?}" "${OUT:?}"
MIGCOM=${MIGCOM:-$(command -v migcom)}
MIG=${MIG:-$(command -v mig)}
CC=${CC:-$(command -v target-clang)}
KERNEL_SRC=$OUT/firehose

mkdir -p "$KERNEL_SRC" "$FAKEROOT/usr/local/lib/kernel" "$FAKEROOT/usr/include/sys/_pthread"

# The SDK private firehose headers. installhdrs installs one of them; the rest
# are in the tree.
for header in "$XNU/libkern/firehose/"*.h; do
	cp -f "$header" "$FAKEROOT/usr/local/include/firehose/"
done

# sys/types.h pulls the SDK's pthread typedef headers; xnu ships the base one.
PTHREAD_DIR=$FAKEROOT/usr/include/sys/_pthread
if [ ! -f "$PTHREAD_DIR/_pthread_attr_t.h" ]; then
	cp "$XNU/EXTERNAL_HEADERS/sys/_pthread/_pthread_types.h" "$PTHREAD_DIR/"
	for spec in attr_t:pthread_attr_t cond_t:pthread_cond_t \
		condattr_t:pthread_condattr_t mutex_t:pthread_mutex_t \
		mutexattr_t:pthread_mutexattr_t once_t:pthread_once_t \
		rwlock_t:pthread_rwlock_t rwlockattr_t:pthread_rwlockattr_t \
		t:pthread_t key_t:pthread_key_t; do
		name=${spec%%:*} type=${spec##*:}
		guard=$(echo "_SYS__PTHREAD_${name}_H_" | tr '[:lower:]' '[:upper:]')
		cat >"$PTHREAD_DIR/_pthread_${name}.h" <<EOF
#ifndef $guard
#define $guard
#include <sys/_pthread/_pthread_types.h>
typedef __darwin_${type} ${type};
#endif
EOF
	done
fi

MIGFLAGS=(-novouchers -DOS_FIREHOSE_SPI=1 -DKERNEL=1 -D__MACH30__)
INC="-I$XNU/osfmk -I$XNU/osfmk/mach -I$XNU/bsd -I$XNU/EXTERNAL_HEADERS \
	-I$LD -I$LD/src -I$LD/src/firehose -I$LD/os -I$KERNEL_SRC"

run_mig() {
	# the .defs file must come last: mig ignores options after a filename
	local defs=$1
	shift
	MIGCC="$CC" MIGCOM="$MIGCOM" bash "$MIG" -arch arm64 -isysroot "$FAKEROOT" \
		"${MIGFLAGS[@]}" $INC "$@" "$defs"
}

run_mig "$LD/src/firehose/firehose.defs" \
	-header "$KERNEL_SRC/firehose.h" -user /dev/null -server /dev/null
run_mig "$LD/src/firehose/firehose_reply.defs" \
	-header /dev/null -user /dev/null -server /dev/null \
	-sheader "$KERNEL_SRC/firehose_replyServer.h"

# firehose_buffer.c calls panic() without the kernel headers that declare it,
# and reaches os/refcnt_internal.h (which uses __improbable) without going
# through sys/cdefs.h first.
cat >"$KERNEL_SRC/firehose_compat.h" <<'EOF'
#ifndef __FIREHOSE_COMPAT_H
#define __FIREHOSE_COMPAT_H
#include <sys/cdefs.h>
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
extern void panic(const char *, ...) __attribute__((noreturn, format(printf, 1, 2)));
#ifdef __cplusplus
}
#endif
#endif
EOF

CFLAGS=(
	-include "$KERNEL_SRC/firehose_compat.h"
	-mkernel -nostdlibinc -Wno-packed
	-DKERNEL=1 -DKERNEL_PRIVATE -DXNU_KERNEL_PRIVATE -DPRIVATE -DIOKIT_KERNEL_PRIVATE
	-DDISPATCH_USE_DTRACE=0 -DOS_FIREHOSE_SPI=1
	-DOS_VOUCHER_ACTIVITY_SPI_TYPES=1 -UOS_VOUCHER_ACTIVITY_SPI
	-I"$LD" -I"$LD/src" -I"$LD/src/firehose" -I"$LD/os" -I"$KERNEL_SRC"
	-I"$FAKEROOT/usr/local/include"
	-I"$FAKEROOT/usr/local/include/kernel"
	-I"$FAKEROOT/usr/local/include/os"
	-I"$FAKEROOT/usr/local/include/firehose"
	-I"$FAKEROOT/System/Library/Frameworks/Kernel.framework/Headers"
	-I"$FAKEROOT/System/Library/Frameworks/Kernel.framework/PrivateHeaders"
	-I"$XNU/EXTERNAL_HEADERS"
	-I"$XNU/osfmk" -I"$XNU/bsd" -I"$XNU/libkern" -I"$XNU/san"
	-c
)

# The boards build plain arm64 (the X2/A710/A510 cores have no pointer
# authentication; the series keeps ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG at
# arm64), so the archive must be arm64 too or ld64 refuses to mix it in.
"$CC" -arch arm64 "${CFLAGS[@]}" "$LD/src/firehose/firehose_buffer.c" \
	-o "$KERNEL_SRC/firehose_buffer.o"

rm -f "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a"
ar crs "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" \
	"$KERNEL_SRC/firehose_buffer.o"
echo "== libfirehose_kernel.a built from $(basename "$LD")"
