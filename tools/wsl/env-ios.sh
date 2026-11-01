#!/usr/bin/env bash
# Environment for building the iOS userland (the CoreAnimation/OpenGL ES
# dylibs and Mesa) on Linux. Source it in a shell that is NOT also using
# tools/wsl/env.sh: both put an `xcrun` first in PATH, and they answer for
# different SDKs (the kernel's fakeroot vs the iPhoneOS SDK).
#
#   source tools/wsl/env-ios.sh
#   tools/gpu/build.sh out/gpu
#   tools/mk-mesa-ios.sh

IOS_TC_PREFIX=${IOS_TC_PREFIX:-$HOME/.local/ios-tc}

if [ ! -x "$IOS_TC_PREFIX/bin/xcrun" ] || [ ! -x "$IOS_TC_PREFIX/cctools/bin/ld" ]; then
	echo "env-ios.sh: $IOS_TC_PREFIX is not bootstrapped" >&2
	echo "env-ios.sh: run tools/wsl/bootstrap-ios-toolchain.sh first" >&2
	return 1 2>/dev/null || exit 1
fi

export IOS_TC_PREFIX
# the iOS shims and the tapi-enabled cctools first
export PATH="$IOS_TC_PREFIX/bin:$IOS_TC_PREFIX/cctools/bin:$PATH"
export IOS_SDK="$IOS_TC_PREFIX/sdk"

# ld64 links against libtapi at run time; the prefix is not in ld.so.conf
export LD_LIBRARY_PATH="$IOS_TC_PREFIX/libtapi/lib:$IOS_TC_PREFIX/cctools/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Mesa's build is long and does not need the kernel toolchain
export JOBS=${JOBS:-$(nproc)}

# bash caches where a command was found; without this a shell that already ran
# clang keeps using /usr/bin/clang after the PATH change above
hash -r 2>/dev/null || true
