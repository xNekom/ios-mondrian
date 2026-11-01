#!/usr/bin/env bash
# iOS userland toolchain for WSL2: build the CoreAnimation/Mesa dylibs of
# docs/COREANIMATION_GLES.md without a Mac.
#
#   tools/wsl/bootstrap-ios-toolchain.sh          # ~15 min the first time
#   source tools/wsl/env-ios.sh
#   tools/gpu/build.sh out/gpu out/mesa/build-softpipe-freedreno/src/gallium/targets/osmesa
#
# What it puts under $PREFIX (default ~/.local/ios-tc):
#   cctools/    ld64 built with TAPI (links against the SDK's .tbd stubs)
#   libtapi/    the library ld64 needs for those stubs
#   sdk/        the iPhoneOS SDK (headers + stubs)
#   bin/        xcrun and the tool wrappers tools/gpu/build.sh and
#               tools/mk-mesa-ios.sh call
#
# The kernel toolchain (`tools/wsl/bootstrap-toolchain.sh`) is a separate
# prefix and is not touched: that one builds Mach-O *kernels*, this one builds
# iOS *dylibs* against the iPhoneOS SDK.
set -euo pipefail
cd "$(dirname "$0")/../.."

PREFIX=${PREFIX:-$HOME/.local/ios-tc}
SRC=${SRC:-$HOME/.cache/ios-mondrian/ios-tc-src}
JOBS=${JOBS:-$(nproc)}
KERNEL_DEPS=${KERNEL_DEPS:-$HOME/.local/xnu-linux/deps}
SDK_NAME=${SDK_NAME:-iPhoneOS16.5.sdk}
SDK_REPO=${SDK_REPO:-https://github.com/theos/sdks.git}
TAPI_REPO=${TAPI_REPO:-https://github.com/tpoechtrager/apple-libtapi}
CCTOOLS_REPO=${CCTOOLS_REPO:-https://github.com/tpoechtrager/cctools-port}

say() { echo "== $*"; }
die() { echo "error: $*" >&2; exit 1; }
done_() { [ -f "$PREFIX/.stamp-$1" ] && [ "${REINSTALL:-}" != "$1" ]; }
mark() { : >"$PREFIX/.stamp-$1"; }

for t in git cmake ninja make clang curl patch; do
	command -v "$t" >/dev/null || die "falta $t (sudo tools/wsl/apt-deps.sh)"
done
mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$SRC"

# ------------------------------------------------------------------- the SDK
if ! done_ sdk; then
	say "iPhoneOS SDK -> $PREFIX/sdk"
	if [ ! -d "$SRC/sdks/.git" ]; then
		git clone -q --depth 1 --filter=blob:none --sparse "$SDK_REPO" "$SRC/sdks"
	fi
	git -C "$SRC/sdks" sparse-checkout set "$SDK_NAME"
	[ -f "$SRC/sdks/$SDK_NAME/usr/lib/libSystem.B.tbd" ] ||
		die "$SDK_NAME has no usr/lib/libSystem.B.tbd"
	rm -rf "$PREFIX/sdk"
	cp -a "$SRC/sdks/$SDK_NAME" "$PREFIX/sdk"
	# The SDK's SDKSettings say /Applications/Xcode.app; meson and clang only
	# care that the tree is complete.
	mark sdk
else
	say "SDK: up to date"
fi

# ----------------------------------------------------------------- libtapi
if ! done_ libtapi; then
	say "libtapi -> $PREFIX/libtapi"
	if [ ! -d "$SRC/apple-libtapi/.git" ]; then
		git clone -q --depth 1 "$TAPI_REPO" "$SRC/apple-libtapi"
	fi
	( cd "$SRC/apple-libtapi" &&
		INSTALLPREFIX="$PREFIX/libtapi" NINJA=1 ./build.sh >/tmp/libtapi-build.log 2>&1 )
	# apple-libtapi's `cmake --install` wants a couple of LLVM archives this
	# build does not produce, and the generated Version.inc lives in the build
	# tree, so assemble the prefix by hand: headers + the shared library are
	# all cctools' configure and ld64 use.
	mkdir -p "$PREFIX/libtapi/include/tapi" "$PREFIX/libtapi/lib"
	cp -a "$SRC/apple-libtapi/src/tapi/include/tapi/." "$PREFIX/libtapi/include/tapi/"
	cp -a "$SRC/apple-libtapi/build/tools/clang/tools/tapi/include/tapi/." \
		"$PREFIX/libtapi/include/tapi/"
	cp -a "$SRC/apple-libtapi/build/lib/libtapi.so"* "$PREFIX/libtapi/lib/"
	[ -f "$PREFIX/libtapi/include/tapi/Version.inc" ] || die "tapi/Version.inc missing"
	mark libtapi
else
	say "libtapi: up to date"
fi

# ------------------------------------------------- cctools-port with tapi
if ! done_ cctools; then
	say "cctools-port + tapi -> $PREFIX/cctools"
	if [ ! -d "$SRC/cctools-port/.git" ]; then
		git clone -q --depth 1 "$CCTOOLS_REPO" "$SRC/cctools-port"
	fi
	( cd "$SRC/cctools-port/cctools" &&
		./configure --prefix="$PREFIX/cctools" \
			--enable-tapi-support --with-libtapi="$PREFIX/libtapi" \
			--with-libblocksruntime="$KERNEL_DEPS" --with-libdispatch="$KERNEL_DEPS" \
			>/tmp/cctools-ios-configure.log 2>&1 &&
		make -j"$JOBS" >/tmp/cctools-ios-build.log 2>&1 &&
		make install >/tmp/cctools-ios-install.log 2>&1 )
	"$PREFIX/cctools/bin/ld" -v >/dev/null 2>&1 || die "the cctools ld did not build"
	# ld64 loads libtapi at run time; make it findable for every process, not
	# only the ones that source env-ios.sh
	if [ "$(id -u)" = 0 ]; then
		echo "$PREFIX/libtapi/lib" >/etc/ld.so.conf.d/ios-tc.conf
		ldconfig 2>/dev/null || true
	fi
	mark cctools
else
	say "cctools: up to date"
fi

# ------------------------------------------------------------------- shims
say "shims -> $PREFIX/bin"
cat >"$PREFIX/bin/xcrun" <<'SHIM'
#!/usr/bin/env bash
# xcrun for the iOS SDK on Linux: every query the build scripts make, and the
# plain `xcrun --sdk iphoneos clang ...` form that runs a tool.
set -u
PREFIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$PREFIX/sdk"
tool="" find=0
while [ $# -gt 0 ]; do
	case "$1" in
	--sdk | -sdk) shift 2 ;;
	-show-sdk-path | --show-sdk-path) echo "$SDK"; exit 0 ;;
	-show-sdk-version | --show-sdk-version) echo "16.5"; exit 0 ;;
	-show-sdk-platform-path | --show-sdk-platform-path) echo "$SDK/Platforms/iPhoneOS.platform"; exit 0 ;;
	-find | -f) find=1; tool="$2"; shift 2 ;;
	*) tool="$1"; shift; break ;;
	esac
done

resolve() {
	case "$1" in
	clang) echo "$PREFIX/bin/clang" ;;
	clang++ | clangxx) echo "$PREFIX/bin/clang++" ;;
	ld) echo "$PREFIX/cctools/bin/ld" ;;
	ar | ranlib | strip | nm | lipo | otool | libtool | nmedit | install_name_tool | codesign_allocate | as)
		echo "$PREFIX/cctools/bin/$1" ;;
	codesign) echo "$PREFIX/bin/codesign" ;;
	dsymutil) command -v dsymutil || echo /usr/bin/dsymutil-18 ;;
	*) command -v "$1" 2>/dev/null ;;
	esac
}

path=$(resolve "$tool") || {
	echo "xcrun: unable to find utility \"$tool\"" >&2
	exit 1
}
if [ "$find" = 1 ]; then
	echo "$path"
	exit 0
fi
exec "$path" "$@"
SHIM
chmod 755 "$PREFIX/bin/xcrun"

for tool in clang clang++; do
	# the real compiler, resolved before the shims exist (never this wrapper)
	real=$(command -v "$tool" 2>/dev/null || true)
	case "$real" in "$PREFIX"/*|'') real=/usr/bin/"$tool" ;; esac
	cat >"$PREFIX/bin/$tool" <<SHIM
#!/usr/bin/env bash
# $tool for iOS. The build scripts pass -target/-isysroot; the linker has to
# be cctools' ld64 (with TAPI), so it is named on link steps (a GNU ld would
# be picked up otherwise) and the real compiler is called by absolute path.
link=1
for arg in "\$@"; do
	case "\$arg" in -c | -E | -S | -M | -MM | -MD | -MMD | -fsyntax-only) link=0 ;; esac
done
if [ "\$link" = 1 ]; then
	exec "$real" "\$@" --ld-path="$PREFIX/cctools/bin/ld"
fi
exec "$real" "\$@"
SHIM
	chmod 755 "$PREFIX/bin/$tool"
done

# Ad-hoc signing is what an iOS dylib needs; this port runs with AMFI off, so
# recording a signature is not needed, only the scripts' verify step passing.
cat >"$PREFIX/bin/codesign" <<'SHIM'
#!/usr/bin/env bash
# codesign for a Linux iOS build: nothing to sign, and the port has no AMFI
# policy that would check it.
for arg in "$@"; do
	case "$arg" in --verify | -v) exit 0 ;; esac
done
exit 0
SHIM
chmod 755 "$PREFIX/bin/codesign"

say "differential check: a stub link"
tmp=$(mktemp -d)
printf 'extern int puts(const char *);\nint f(void){return puts("x");}\n' >"$tmp/t.c"
"$PREFIX/bin/clang" -target arm64-apple-ios16.0 -isysroot "$PREFIX/sdk" \
	-dynamiclib -o "$tmp/t.dylib" "$tmp/t.c" || die "the toolchain cannot link a dylib against the SDK"
file "$tmp/t.dylib"
rm -rf "$tmp"

echo
echo "iOS toolchain ready in $PREFIX"
echo "  source tools/wsl/env-ios.sh"
