#!/usr/bin/env bash
# Build the Mach-O cross toolchain that lets XNU compile on Linux (WSL2), no Mac.
#
#   sudo tools/wsl/apt-deps.sh               # system packages, once
#   tools/wsl/bootstrap-toolchain.sh         # install into ~/.local/xnu-linux
#   PREFIX=/opt/xnu-linux tools/wsl/bootstrap-toolchain.sh
#   REINSTALL=cctools tools/wsl/bootstrap-toolchain.sh
#
# What it installs under $PREFIX:
#   cctools/bin/   Apple ld64 (from cctools-port), ar, strip, nm, otool, lipo,
#                  libtool, nmedit, ranlib, codesign_allocate, ctf_insert
#   bin/           mig + migcom (bootstrap_cmds cross_platform branch) and the
#                  macOS shims (xcrun, plutil, iig, target-clang, ...)
#   versions.txt   the commit of every source tree, so a build is reproducible
#
# Why cctools-port's ld64 and not ld64.lld: XNU's kernel link line uses
# -image_base, -segaddr, -segment_order, -alias_list, -version_load_command,
# -new_linker and -ios_version_min, none of which ld64.lld implements; without
# them the kernel lands at __TEXT 0 and the prelink/kext binding breaks. ar and
# ranlib must be cctools' too: GNU ar archives are rejected by ld64, which then
# drops the whole .a silently.
#
# Idempotent: each component leaves a stamp in $PREFIX/.stamp-<name> and is
# skipped afterwards, so re-running resumes after a failure.
set -euo pipefail
cd "$(dirname "$0")/../.."

PREFIX=${PREFIX:-$HOME/.local/xnu-linux}
SRC=${SRC:-$HOME/.cache/ios-mondrian/xnu-linux-src}
DEPS=$PREFIX/deps
JOBS=${JOBS:-$(nproc)}
REINSTALL=${REINSTALL:-}
CCTOOLS_REPO=${CCTOOLS_REPO:-https://github.com/tpoechtrager/cctools-port}
BOOTSTRAP_REPO=${BOOTSTRAP_REPO:-https://github.com/markmentovai/bootstrap_cmds}
BOOTSTRAP_BRANCH=${BOOTSTRAP_BRANCH:-cross_platform}
LIBDISPATCH_REPO=${LIBDISPATCH_REPO:-https://github.com/apple/swift-corelibs-libdispatch}
BLOCKS_REPO=${BLOCKS_REPO:-https://github.com/mackyle/blocksruntime}
# The macOS-tool shims (xcrun, plutil, codesign, target-clang, iig, ...) are
# fetched at a pinned commit instead of vendored: the iig implementation alone
# is a DriverKit interface generator, and the wrappers encode the xnu make
# quirks (host vs target clang, -mmacosx-version-min detection) that took a full
# port to get right. Our own tools/wsl/shim wins over this tree.
SHIMS_REPO=${SHIMS_REPO:-https://github.com/Allenwdk/xnu-linux-toolchain}
SHIMS_SHA=${SHIMS_SHA:-909990e4ec2c6cda30c20cdb23219946918c7fd6}

say() { echo "== $*"; }
die() { echo "error: $*" >&2; exit 1; }

for t in git make cmake clang curl cc; do
	command -v "$t" >/dev/null || die "falta $t (sudo tools/wsl/apt-deps.sh)"
done

mkdir -p "$PREFIX/bin" "$PREFIX/cctools" "$DEPS" "$SRC"
: >"$PREFIX/versions.txt"

# component done?  (REINSTALL=<name> forces one)
done_() { [ -f "$PREFIX/.stamp-$1" ] && [ "${REINSTALL:-}" != "$1" ]; }
mark() { : >"$PREFIX/.stamp-$1"; }

# git fetch --depth 1 into DIR at REF; the resolved commit goes to versions.txt
fetch() {
	_dir=$1 _repo=$2 _ref=$3
	if [ ! -d "$_dir/.git" ]; then
		mkdir -p "$_dir"
		git -C "$_dir" init -q
	fi
	git -C "$_dir" fetch -q --depth 1 "$_repo" "$_ref" || die "fetch $_repo $_ref"
	git -C "$_dir" checkout -qf FETCH_HEAD
	printf '%s\t%s\t%s\n' "$(basename "$_dir")" "$_repo" \
		"$(git -C "$_dir" rev-parse HEAD)" >>"$PREFIX/versions.txt"
}

# ---------------------------------------------------------------- blocksruntime
if ! done_ blocksruntime; then
	say "blocksruntime -> $DEPS"
	fetch "$SRC/blocksruntime" "$BLOCKS_REPO" "${BLOCKS_REF:-master}"
	( cd "$SRC/blocksruntime" && CC=clang CFLAGS=-fPIC ./buildlib )
	mkdir -p "$DEPS/lib" "$DEPS/include"
	cp "$SRC/blocksruntime/libBlocksRuntime.a" "$DEPS/lib/"
	cp "$SRC/blocksruntime/BlocksRuntime/"*.h "$DEPS/include/"
	mark blocksruntime
else
	say "blocksruntime: up to date"
fi

# ------------------------------------------------------------------ libdispatch
# cctools-port's ld64 needs libdispatch + a blocks runtime. Built static,
# without tests, and without the project's -Werror (newer clang trips on it).
if ! done_ libdispatch; then
	say "libdispatch -> $DEPS"
	fetch "$SRC/swift-corelibs-libdispatch" "$LIBDISPATCH_REPO" "${LIBDISPATCH_REF:-main}"
	sed -i 's|:-Werror>)|:-Werror> $<$<COMPILE_LANGUAGE:C,CXX>:-Wno-error>)|' \
		"$SRC/swift-corelibs-libdispatch/cmake/modules/DispatchCompilerWarnings.cmake" 2>/dev/null || true
	cmake -S "$SRC/swift-corelibs-libdispatch" -B "$SRC/swift-corelibs-libdispatch/build" \
		-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS" \
		-DBUILD_TESTING=OFF -DINSTALL_PRIVATE_HEADERS=ON \
		-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
	cmake --build "$SRC/swift-corelibs-libdispatch/build" -j"$JOBS"
	cmake --install "$SRC/swift-corelibs-libdispatch/build"
	mark libdispatch
else
	say "libdispatch: up to date"
fi

# ------------------------------------------------------------------ cctools-port
if ! done_ cctools; then
	say "cctools-port -> $PREFIX/cctools (LD64, ar, strip, otool, lipo, ...)"
	fetch "$SRC/cctools-port" "$CCTOOLS_REPO" "${CCTOOLS_REF:-master}"
	# No --target: an unprefixed ld/ar/strip is what xnu's make variables want.
	( cd "$SRC/cctools-port/cctools" &&
		./configure --prefix="$PREFIX/cctools" \
			--with-libblocksruntime="$DEPS" --with-libdispatch="$DEPS" &&
		make -j"$JOBS" && make install )
	# the kernel's SETUP tools include <mach-o/*.h>; cctools installs the
	# libraries but not its include tree
	mkdir -p "$PREFIX/cctools/include"
	cp -R "$SRC/cctools-port/cctools/include/." "$PREFIX/cctools/include/"
	mark cctools
else
	say "cctools: up to date"
fi

# --------------------------------------------------------------- bootstrap_cmds
# Apple's MIG lives in bootstrap_cmds, not in cctools. markmentovai's
# cross_platform branch is the autoconf port; it builds migcom + mig.sh with no
# patches and copes with the modern .defs (-mach_msg2 included).
if ! done_ mig; then
	say "bootstrap_cmds (mig/migcom) -> $PREFIX/bin"
	fetch "$SRC/bootstrap_cmds" "$BOOTSTRAP_REPO" "$BOOTSTRAP_BRANCH"
	( cd "$SRC/bootstrap_cmds" && autoreconf --install >/dev/null &&
		sh configure --prefix="$PREFIX" >/dev/null && make -j"$JOBS" )
	install -m755 "$SRC/bootstrap_cmds/migcom.tproj/migcom" "$PREFIX/bin/migcom"
	install -m755 "$SRC/bootstrap_cmds/migcom.tproj/mig.sh" "$PREFIX/bin/mig"
	mark mig
else
	say "mig: up to date"
fi

# ------------------------------------------------------------------- macOS shims
if ! done_ shims; then
	say "macOS tool shims -> $PREFIX/bin"
	fetch "$SRC/xnu-linux-toolchain" "$SHIMS_REPO" "$SHIMS_SHA"
	install -m755 "$SRC/xnu-linux-toolchain/toolchain/"* "$PREFIX/bin/" 2>/dev/null || true
	mark shims
else
	say "shims: up to date"
fi
# their unifdef shim expects a binary built from source; the distro package is
# the same tool and apt-deps.sh installs it
printf '#!/bin/sh\nexec /usr/bin/unifdef "$@"\n' >"$PREFIX/bin/unifdef"
chmod 0755 "$PREFIX/bin/unifdef"
# ours are copied on every run: they are small, they change often, and a stale
# xcrun/target-clang is a build failure that looks like a toolchain problem
find tools/wsl/shim -maxdepth 1 -type f \( -name '*.h' -o -perm -u+x \) \
	-exec cp -f {} "$PREFIX/bin/" \;
mkdir -p "$PREFIX/bin/compat"
cp -fR tools/wsl/shim/compat/. "$PREFIX/bin/compat/"
chmod 0755 "$PREFIX"/bin/xcrun "$PREFIX"/bin/target-clang "$PREFIX"/bin/target-clang++ \
	"$PREFIX"/bin/host-clang "$PREFIX"/bin/host-clang++ "$PREFIX"/bin/python
chmod 0644 "$PREFIX"/bin/hostcompat.h

# BSD calls the SETUP host tools need (setmode/getmode, fcopyfile) plus the
# libmacho pieces cctools does not ship (mach-o/swap.h, NXGetLocalArchInfo).
# Built with the system compiler: these are Linux binaries that run at build
# time, not Mach-O objects the kernel links. The source hash decides whether a
# rebuild is needed, so editing a shim is never silently ignored.
HOSTCOMPAT_SUM=$(cat tools/wsl/shim/hostcompat.c tools/wsl/shim/swapmacho.c \
	tools/wsl/shim/compat/*.h tools/wsl/shim/compat/*/*.h tools/wsl/shim/compat/*/*/*.h 2>/dev/null |
	sha256sum | cut -d' ' -f1)
if [ ! -f "$PREFIX/lib/libhostcompat.a" ] ||
	[ "$(cat "$PREFIX/lib/.hostcompat.sum" 2>/dev/null)" != "$HOSTCOMPAT_SUM" ]; then
	say "libhostcompat -> $PREFIX/lib"
	mkdir -p "$PREFIX/lib"
	cc -O1 -c -Itools/wsl/shim/compat tools/wsl/shim/hostcompat.c -o "$SRC/hostcompat.o"
	cc -O1 -c -Itools/wsl/shim/compat -I"$PREFIX/cctools/include" \
		-idirafter "$PREFIX/cctools/include/foreign" -D__LITTLE_ENDIAN__=1 \
		tools/wsl/shim/swapmacho.c -o "$SRC/swapmacho.o"
	rm -f "$PREFIX/lib/libhostcompat.a"
	ar rcs "$PREFIX/lib/libhostcompat.a" "$SRC/hostcompat.o" "$SRC/swapmacho.o"
	echo "$HOSTCOMPAT_SUM" >"$PREFIX/lib/.hostcompat.sum"
fi

say "checking the toolchain"
"$PREFIX/cctools/bin/ld" -v 2>&1 | head -2
"$PREFIX/bin/migcom" -version 2>&1 | head -1 || true
echo
echo "toolchain ready in $PREFIX"
cat "$PREFIX/versions.txt"
echo "  source tools/wsl/env.sh   # then tools/wsl/build-kernel.sh"
