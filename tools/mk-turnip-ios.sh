#!/bin/bash
# Build Turnip, Mesa's Vulkan driver for the Adreno, for the iOS 16 arm64
# userland on Linux/WSL 2 -- no Mac, no Xcode.
#
#   tools/mk-turnip-ios.sh                    # Mesa 25.0.7 from out/mesa/*.tar.xz
#   MESA_TARBALL=/path/to/mesa-25.0.7.tar.xz tools/mk-turnip-ios.sh
#
# The pieces a Mac has and Linux does not are replaced like this:
#
#   Xcode SDK        -> /root/sdks/iPhoneOS16.5.sdk (the theos iPhoneOS SDK,
#                       the same one HackiOS builds its userland against)
#   Xcode clang      -> host clang 18 with -target arm64-apple-ios16.5
#   Apple ld64       -> LLVM's ld64.lld, which reads the SDK's .tbd stubs
#                       (cctools-port's ld64 in /opt/unixnu-linux predates .tbd)
#   Xcode ar/ranlib  -> cctools' Mach-O ar/ranlib from /opt/unixnu-linux
#
# What comes out: out/mesa-turnip/stage/libvulkan_freedreno.dylib, install name
# /usr/lib/libvulkan_freedreno.dylib, ad-hoc signed. Turnip's msm back end talks
# to MondrianGPU through tools/mesa/turnip-drm, the stand-in for libdrm; the
# patch that wires it in is tools/mesa/turnip-darwin.patch, ported from
# HackiOS (oosexgang/hakios-xnu-kernel, tools/mesa/{turnip-darwin.patch,
# hakios-drm}), which runs this same stack over its own msm DRM user client.
#
# Needs: meson, ninja, python3 with mako, glslangValidator (apt: glslang-tools).
set -euo pipefail

VERSION=25.0.7
root=$(cd "$(dirname "$0")/.." && pwd)
out=${OUT:-$root/out/mesa-turnip}
tarball=${MESA_TARBALL:-$root/out/mesa/mesa-$VERSION.tar.xz}
sdk=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
tc=${MACHO_TOOLCHAIN:-/opt/unixnu-linux/CommandLineTools/usr/bin}
lld=${LD64_LLD:-/usr/lib/llvm-18/bin/ld64.lld}
cc=${IOS_CLANG:-/usr/bin/clang}
src=$out/mesa-$VERSION
build=$out/build-turnip
stage=$out/stage
target=arm64-apple-ios16.5

for f in "$sdk/usr/lib/libSystem.tbd" "$lld" "$tc/ar" "$tc/install_name_tool"; do
	[ -e "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done
command -v glslangValidator >/dev/null ||
	{ echo "error: glslangValidator is needed (apt: glslang-tools)" >&2; exit 1; }
command -v meson >/dev/null || { echo "error: meson is needed" >&2; exit 1; }
command -v ninja >/dev/null || { echo "error: ninja is needed" >&2; exit 1; }

mkdir -p "$out"
if [ ! -f "$src/meson.build" ]; then
	[ -f "$tarball" ] || {
		echo "error: no Mesa tarball at $tarball" >&2
		echo "       (tools/mk-mesa-ios.sh fetches mesa-$VERSION.tar.xz)" >&2
		exit 1
	}
	echo "== extracting $(basename "$tarball")"
	rm -rf "$src"
	tar xJf "$tarball" -C "$out"
fi

echo "== applying tools/mesa/turnip-darwin.patch"
if [ ! -f "$src/.turnip-patched" ]; then
	(cd "$src" && patch -p1 --forward < "$root/tools/mesa/turnip-darwin.patch")
	# A Mach-O dylib has no build id: ir3 keeps no disk cache, as in the GL build.
	(cd "$src" && patch -p1 --forward < "$root/tools/mesa/turnip-ir3-nocache.patch")
	# the stand-in for libdrm, where the patch's meson hunk looks for it
	rm -rf "$src/src/mondrian-turnip-drm"
	cp -R "$root/tools/mesa/turnip-drm" "$src/src/mondrian-turnip-drm"
	touch "$src/.turnip-patched"
fi

cat > "$out/cross.ini" <<INI
[binaries]
c = ['$cc', '-target', '$target', '-isysroot', '$sdk', '--ld-path=$lld']
cpp = ['$cc', '-target', '$target', '-isysroot', '$sdk', '--ld-path=$lld']
objc = ['$cc', '-target', '$target', '-isysroot', '$sdk', '--ld-path=$lld']
objcpp = ['$cc', '-target', '$target', '-isysroot', '$sdk', '--ld-path=$lld']
ar = '$tc/ar'
ranlib = '$tc/ranlib'
strip = '$tc/strip'
pkg-config = 'false'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
# meson's has_header_symbol('time.h', 'struct timespec') comes back false for
# this SDK, and src/c11/time.h then defines the struct again; Darwin has it.
# -D_DARWIN_C_SOURCE: Mesa compiles with -std=c11, which on Darwin hides the
# POSIX declarations the SDK gates on __DARWIN_C_LEVEL (Dl_info/dladdr in
# <dlfcn.h> is the first one the build meets).
c_args = ['-DHAVE_STRUCT_TIMESPEC', '-D_DARWIN_C_SOURCE', '-DHAVE_DLFCN_H']
# -Wno-c++11-narrowing: Turnip's braced initialisers narrow (uint32_t into a
# uint16_t field of tu_cs.h's memctx and friends); the values fit, and clang 18
# makes it an error where the compiler HackiOS builds with lets it through.
cpp_args = ['-DHAVE_STRUCT_TIMESPEC', '-D_DARWIN_C_SOURCE', '-DHAVE_DLFCN_H',
            '-Wno-c++11-narrowing']
c_link_args = ['-Wl,-platform_version,ios,16.5,16.5']
cpp_link_args = ['-Wl,-platform_version,ios,16.5,16.5']
INI

if [ ! -f "$build/build.ninja" ]; then
	echo "== configuring $build"
	meson setup "$build" "$src" --cross-file "$out/cross.ini" --wrap-mode=nofallback \
		--prefix=/usr --libdir=lib --buildtype=release -Db_ndebug=true \
		-Dplatforms= -Dgallium-drivers= -Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=msm -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
		-Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=disabled \
		-Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled \
		-Dshader-cache=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
		-Dglvnd=disabled -Dvideo-codecs= -Dtools= -Dbuild-tests=false \
		> "$out/turnip-setup.log"
fi

echo "== building libvulkan_freedreno"
ninja -C "$build" src/freedreno/vulkan/libvulkan_freedreno.dylib > "$out/turnip-ninja.log"

echo "== staging $stage"
rm -rf "$stage"
mkdir -p "$stage"
cp "$build/src/freedreno/vulkan/libvulkan_freedreno.dylib" "$stage/"
"$tc/install_name_tool" -id /usr/lib/libvulkan_freedreno.dylib \
	"$stage/libvulkan_freedreno.dylib"
codesign --force --sign - --timestamp=none "$stage/libvulkan_freedreno.dylib" 2>/dev/null ||
	echo "   (not signed: codesign failed, the dylib may still load)"

# The phone-side check: one fill through Turnip, read back word by word.
echo "== building vk_test"
"$cc" -target "$target" -isysroot "$sdk" --ld-path="$lld" \
	-Wl,-platform_version,ios,16.5,16.5 -O2 -Wall \
	-I"$src/include" -o "$stage/vk_test" "$root/tools/gpu/vk_test.c"
codesign --force --sign - --timestamp=none "$stage/vk_test" 2>/dev/null || true

file "$stage/libvulkan_freedreno.dylib" "$stage/vk_test"
ls -l "$stage"
