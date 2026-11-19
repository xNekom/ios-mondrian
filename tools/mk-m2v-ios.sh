#!/bin/bash
# Build UniXNU's Metal on Vulkan for the iOS 16 arm64 userland on Linux/WSL 2:
# AdrenoMetal's frontend (the Metal objects, MIT) over its bridge to
# steelbrain's metal2vulkan runtime (Rust), whose Vulkan is Turnip
# (tools/mk-turnip-ios.sh). The build inputs of tools/m2v/ and the shape of
# this script are ported from HakiOS (oosexgang/hakios-xnu-kernel, MIT), which
# runs the same stack over its own msm DRM user client.
#
# What comes out, in out/m2v/out/: frontend.o and libadreno_metal_bridge.a,
# linked into a program (m2v_test) with -framework Foundation Metal IOSurface
# CoreFoundation -lc++.
#
# Needs: rustup's cargo with the aarch64-apple-ios target, LLVM 21's
# llvm-as/llvm-ar/ld64.lld (the pinned .ll fixtures use `captures(none)`,
# which LLVM 18 rejects), clang, and the theos iPhoneOS16.5 SDK.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
B=${M2V_WORK:-$root/out/m2v}
SDK=${IOS_SDK:-/root/sdks/iPhoneOS16.5.sdk}
MESA=${MESA_TREE:-$root/out/mesa-turnip/mesa-25.0.7}
M2V_PIN=624bab3918de5b978e1101517abca2b4fa426565	# steelbrain/metal2vulkan, branch development
AM_PIN=243d63cf43305a85c8119b66b49cb7df4b30b019		# UniXNU/AdrenoMetal
export PATH=$HOME/.cargo/bin:$PATH

command -v cargo >/dev/null || { echo "no cargo (rustup, target aarch64-apple-ios)" >&2; exit 1; }
LLVM_AS=$(command -v llvm-as-21 || command -v llvm-as) || { echo "no llvm-as (apt: llvm-21)" >&2; exit 1; }
LLVM_AR=$(command -v llvm-ar-21 || command -v llvm-ar) || { echo "no llvm-ar (apt: llvm-21)" >&2; exit 1; }
[ -d "$MESA/include" ] || { echo "no Mesa tree at $MESA: tools/mk-turnip-ios.sh first" >&2; exit 1; }

mkdir -p "$B/out" "$B/obj"
cd "$B"
fetch() {	# repository, revision, directory, patches...
	local url=$1 rev=$2 dir=$3 p; shift 3
	if [ ! -d "$dir" ]; then
		git clone -q --filter=blob:none "$url" "$dir"
		git -C "$dir" checkout -q "$rev"
	fi
	[ "$(git -C "$dir" rev-parse HEAD)" = "$rev" ] || { echo "$dir is not at $rev" >&2; exit 1; }
	# A tree that is already there may be unpatched (a clone made outside this
	# script, or a run that stopped early): apply what still applies. A patch
	# that is already in refuses --check and is left alone; one that fails
	# half-way still stops the build at its error.
	for p; do
		if git -C "$dir" apply --check "$p" 2>/dev/null; then
			git -C "$dir" apply "$p"
		fi
	done
}
fetch https://github.com/UniXNU/AdrenoMetal.git "$AM_PIN" AdrenoMetal "$root/tools/m2v/adrenometal-ios16.patch"
A=$B/AdrenoMetal
fetch https://github.com/steelbrain/metal2vulkan.git "$M2V_PIN" metal2vulkan "$A/bridge/patches/00"*.patch "$root/tools/m2v/metal2vulkan-hakios.patch"
S=$B/metal2vulkan

$LLVM_AS -o obj/runtime_examples.air "$S/crates/metal2vulkan-validation/fixtures/public/examples/runtime_examples.ll"
$LLVM_AS -o obj/function_constant.air "$S/crates/metal2vulkan-validation/fixtures/public/kernel_function_constant_gate_fold.ll"
$LLVM_AS -o obj/scanout_convert.air "$A/shaders/scanout_convert.ll"

mkdir -p bridge
cat > bridge/Cargo.toml <<EOF
[package]
name = "adreno-metal-bridge"
version = "0.1.0"
edition = "2024"
rust-version = "1.85"
[workspace]
[lib]
crate-type = ["staticlib"]
path = "$A/bridge/NativeMetalBridge.rs"
[dependencies]
metal2vulkan = { path = "$S/crates/metal2vulkan", features = ["ash"] }
metal2vulkan-runtime = { path = "$S/crates/metal2vulkan-runtime" }
libc = "0.2"
sha2 = { version = "0.10", features = ["asm"] }
[profile.release]
panic = "unwind"
# No debug info: it is two thirds of the artifact (22 MB against 10 MB), and a
# wfile costs the file's size in kernel memory and one upload per experiment.
# The frontend's own symbols, where the Metal objects live, are kept.
debug = 0
strip = "debuginfo"
lto = "fat"
codegen-units = 1
EOF

echo "== cargo build (this takes a while)"
if ! CC_aarch64_apple_ios=clang CFLAGS_aarch64_apple_ios="-target arm64-apple-ios16.0 -isysroot $SDK" \
	AR_aarch64_apple_ios=$LLVM_AR IPHONEOS_DEPLOYMENT_TARGET=16.0 SDKROOT=$SDK \
	NMB_RUNTIME_ID=$(echo "$M2V_PIN" | cut -c1-32) NMB_FIXTURE_AIR=$B/obj/runtime_examples.air \
	NMB_FC_AIR=$B/obj/function_constant.air NMB_SCANOUT_AIR=$B/obj/scanout_convert.air \
	cargo build --release --manifest-path bridge/Cargo.toml --target aarch64-apple-ios \
		--target-dir target > cargo.log 2>&1; then
	tail -30 cargo.log >&2
	exit 1
fi
cp target/aarch64-apple-ios/release/libadreno_metal_bridge.a out/

echo "== frontend"
clang++ -target arm64-apple-ios16.0 -isysroot "$SDK" -O2 -std=c++17 -fobjc-arc \
	-Wno-deprecated-declarations -include "$root/tools/m2v/ios16-compat.h" \
	-I "$A" -I "$MESA/include" -x objective-c++ -c "$A/NativeBridgeMetalFrontend.mm" \
	-o out/frontend.o

echo "== m2v_test"
# -x objective-c must not reach the .o/.a on the same line: clang then reads
# the archive as source and dies on its symbol table. -x none ends the scope.
clang -target arm64-apple-ios16.0 -isysroot "$SDK" -O2 -fobjc-arc \
	-o out/m2v_test -x objective-c "$root/tools/gpu/m2v_test.m" -x none \
	out/frontend.o out/libadreno_metal_bridge.a \
	-framework Foundation -framework Metal -framework IOSurface -framework CoreFoundation -lc++ \
	-Wl,-platform_version,ios,16.0,16.0 --ld-path=$(command -v ld64.lld-21 || echo /usr/lib/llvm-18/bin/ld64.lld)

echo "== libmondrianmetal.dylib"
# The same device as a dylib a process can dlopen or be given by name, for
# WebKit's GPU process: the frontend and the runtime, plus the interposer in
# tools/gpu/mondrian-metal-provider.m that makes MTLCreateSystemDefaultDevice
# answer with it. Installed at /private/var/vm/ by wfile, not flashed.
clang -target arm64-apple-ios16.0 -isysroot "$SDK" -O2 -fobjc-arc -c \
	-x objective-c "$root/tools/gpu/mondrian-metal-provider.m" -o out/provider.o
clang -target arm64-apple-ios16.0 -isysroot "$SDK" -O2 -fobjc-arc -dynamiclib \
	-o out/libmondrianmetal.dylib out/provider.o out/frontend.o out/libadreno_metal_bridge.a \
	-framework Foundation -framework Metal -framework IOSurface -framework CoreFoundation -lc++ \
	-Wl,-platform_version,ios,16.0,16.0 \
	-Wl,-install_name,/private/var/vm/libmondrianmetal.dylib \
	--ld-path=$(command -v ld64.lld-21 || echo /usr/lib/llvm-18/bin/ld64.lld)

echo "== metal_probe"
clang -target arm64-apple-ios16.0 -isysroot "$SDK" -O2 -fobjc-arc \
	-o out/metal_probe -x objective-c "$root/tools/gpu/metal_probe.m" -x none \
	-framework Foundation -framework Metal \
	-Wl,-platform_version,ios,16.0,16.0 \
	--ld-path=$(command -v ld64.lld-21 || echo /usr/lib/llvm-18/bin/ld64.lld)

echo "mk-m2v-ios.sh: $B/out:"
ls -l out
