#!/bin/bash
# Build Mesa's freedreno + OSMesa for the iOS 16 arm64 userland on this Mac,
# with tools/mesa/mondrian-drm standing in for libdrm. UNTESTED ON HARDWARE:
# the build is known to produce a dylib, no frame has been rendered with it.
#
#   tools/mk-mesa-ios.sh                      # fetch Mesa 25.0.7 into out/mesa
#   MESA=/path/to/mesa-25.0.7 tools/mk-mesa-ios.sh
#   MESA=/path/to/mesa-git tools/mk-mesa-ios.sh   # same version, from a clone
#
# Everything is written under out/mesa: the source, the meson build directory,
# the venv with meson, and stage/, which holds the result.
#
# The kernel side is the MondrianGPU service (iokit/Kernel/arm/MondrianGPU.cpp,
# patches 0181-0182); nothing here touches the phone.
#
# Requires: Xcode (the iphoneos SDK), ninja, python3, patch, and GNU bison 3
# (Mesa's ir3 parser needs it; `brew install bison` and this script finds it).
set -euo pipefail

VERSION=25.0.7
SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
root=$(cd "$(dirname "$0")/.." && pwd)
out=${OUT:-$root/out/mesa}
src=${MESA:-$out/mesa-$VERSION}
stage=$out/stage
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
cc=$(xcrun --sdk iphoneos -f clang)
cxx=$(xcrun --sdk iphoneos -f clang++)
drivers=softpipe,freedreno
build=$out/build-${drivers//,/-}
target=arm64-apple-ios16.0

# Mesa's ir3 grammar needs bison 3, and Apple ships bison 2.3.
if ! bison --version 2>/dev/null | head -1 | grep -q '^bison (GNU Bison) 3\.'; then
	if [ -x /opt/homebrew/opt/bison/bin/bison ]; then
		PATH=/opt/homebrew/opt/bison/bin:$PATH
	else
		echo "error: bison 3 is needed; brew install bison" >&2
		exit 1
	fi
fi

# Mesa 25.0.7 itself, from the tarball the release notes publish.
if [ ! -f "$src/meson.build" ]; then
	if [ -n "${MESA:-}" ]; then
		echo "error: no Mesa tree at $MESA" >&2
		exit 1
	fi
	mkdir -p "$out"
	if [ ! -f "$out/mesa-$VERSION.tar.xz" ]; then
		echo "== fetching mesa-$VERSION.tar.xz"
		curl -sL --fail -o "$out/mesa-$VERSION.tar.xz" \
			"https://archive.mesa3d.org/mesa-$VERSION.tar.xz"
	fi
	echo "$SHA256  $out/mesa-$VERSION.tar.xz" | shasum -a 256 -c --quiet
	rm -rf "$src"
	tar xJf "$out/mesa-$VERSION.tar.xz" -C "$out"
fi
tree_version=$(cat "$src/VERSION" 2>/dev/null || echo unknown)
if [ "$tree_version" != "$VERSION" ]; then
	echo "error: $src is Mesa $tree_version; tools/mesa/mondrian-darwin.patch" \
		"is written for $VERSION" >&2
	exit 1
fi

# The shim, at the path the patch builds it from.
rm -rf "$src/src/mondrian-drm"
cp -R "$root/tools/mesa/mondrian-drm" "$src/src/mondrian-drm"

# The Darwin edits: freedreno's drm layer built without Linux's DRM, its
# buffers mapped by the kernel's user client, and OSMesa able to create the
# GPU's screen instead of only the software one. The patched meson.build is the
# mark of a tree that has them, so a second run does not patch again and a
# reverted tree is patched again.
patchfile=$root/tools/mesa/mondrian-darwin.patch
if grep -q "mondrian-drm" "$src/meson.build"; then
	echo "== $(basename "$src") is already patched"
else
	echo "== patching $(basename "$src")"
	if ! patch -p1 -d "$src" --batch --forward --no-backup-if-mismatch \
		< "$patchfile"; then
		echo "error: $src is not a clean Mesa $VERSION tree; restore it" \
			"(git checkout .) or delete it and run this again" >&2
		exit 1
	fi
fi

# meson, and the python modules Mesa's generators import.
if [ ! -x "$out/venv/bin/meson" ]; then
	echo "== creating $out/venv"
	python3 -m venv "$out/venv"
	"$out/venv/bin/pip" -q install meson mako pyyaml packaging
fi
export PATH=$out/venv/bin:$PATH

# Meson's cross file: an iOS target built by the SDK's clang, and no program
# built here can run there (needs_exe_wrapper, which is what Mesa expects of a
# cross build with no tools enabled).
mkdir -p "$out"
cat > "$out/cross.ini" <<INI
[binaries]
c = ['$cc', '-target', '$target', '-isysroot', '$sdk']
cpp = ['$cxx', '-target', '$target', '-isysroot', '$sdk', '-fuse-cxa-atexit']
objc = ['$cc', '-target', '$target', '-isysroot', '$sdk']
ar = '$(xcrun -f ar)'
ranlib = '$(xcrun -f ranlib)'
strip = '$(xcrun -f strip)'
pkg-config = 'false'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
INI

echo "== configuring $build"
meson setup "$build" "$src" --cross-file "$out/cross.ini" --wrap-mode=nofallback \
	--prefix=/usr --libdir=lib --buildtype=release -Db_ndebug=true \
	-Dplatforms= -Dgallium-drivers="$drivers" -Dfreedreno-kmds=msm \
	-Dvulkan-drivers= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
	-Dosmesa=true -Dllvm=disabled -Dshared-glapi=enabled -Dgles1=disabled \
	-Dgles2=enabled -Dopengl=true -Dzstd=disabled -Dxmlconfig=disabled \
	-Dexpat=disabled -Dshader-cache=disabled -Dvalgrind=disabled \
	-Dlibunwind=disabled -Dglvnd=disabled -Dvideo-codecs= -Dtools= \
	-Dgallium-vdpau=disabled -Dgallium-va=disabled -Dgallium-xa=disabled \
	-Dlmsensors=disabled -Dbuild-tests=false > "$out/meson-setup.log"

echo "== building libOSMesa"
ninja -C "$build" src/gallium/targets/osmesa/libOSMesa.8.dylib \
	> "$out/ninja.log"

# Stage the dylib at the path the iOS root uses for it, stripped, with the
# gl.xml the userland needs to look entry points up.
echo "== staging $stage"
rm -rf "$stage"
mkdir -p "$stage"
$(xcrun -f strip) -x -o "$stage/libOSMesa.8.dylib" \
	"$build/src/gallium/targets/osmesa/libOSMesa.8.dylib"
install_name_tool -id /usr/lib/libOSMesa.8.dylib "$stage/libOSMesa.8.dylib"
# Ad-hoc: iOS refuses an unsigned dylib, and the signature must come last.
codesign --force --sign - --timestamp=none "$stage/libOSMesa.8.dylib"
codesign --verify --strict "$stage/libOSMesa.8.dylib"
cp "$src/src/mapi/glapi/registry/gl.xml" "$stage/gl.xml"
nm -gU "$stage/libOSMesa.8.dylib" | awk '$3 ~ /^_gl/ { print substr($3, 2) }' \
	> "$stage/exported-gl.txt"
file "$stage/libOSMesa.8.dylib"
ls -l "$stage"

cat <<'NOTE'

libOSMesa.8.dylib is the OSMesa of the mondrian-drm patch: it creates the
freedreno screen from the MondrianGPU service and falls back to softpipe when
that fails (OSMESA_SOFTWARE=1 forces the fallback). Untested on hardware, and
these are missing: relocations (the kernel refuses nr_relocs != 0, freedreno
uses softpin), prime file descriptors and syncobjs (ENOSYS), and the IOSurface
path that would present frames (request 0x7e, not in the kernel yet).
NOTE
