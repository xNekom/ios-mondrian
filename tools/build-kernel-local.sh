#!/bin/bash
# Build the mondrian XNU kernel on this Mac, the same way the CI does.
#
#   tools/build-kernel-local.sh          # build DEVELOPMENT for mondrian
#   KERNEL_CONFIG=RELEASE tools/build-kernel-local.sh
#   DXB_DIR=~/dxb tools/build-kernel-local.sh   # keep the tree elsewhere
#
# What it does (the steps of .github/workflows/xnu.yml):
#   1. ensures the blacktop/darwin-xnu-build checkout at the pinned commit
#      (DXB_DIR, default /private/tmp/dxblocal) and a PATH with jq, cmake,
#      ninja and stubs for gum/xcodes when they are not installed;
#   2. copies this repo's xnu/patches-mondrian/*.patch (and the staging
#      scripts) into dxb/patches, next to blacktop's own;
#   3. patches build.sh so libfirehose_kernel is built for plain arm64
#      (our kernels are not arm64e);
#   4. resets the xnu checkout so every patch applies to a clean tree;
#   5. runs build.sh (log in /tmp/kernel-local.log), fails if a numbered
#      patch was skipped, and copies the kernel to
#      /tmp/kernel.development.mondrian with its sha256.
#
# Requires Xcode (its iig must be the one of the xnu generation: Xcode 15
# for xnu-8796) and Homebrew's jq/cmake/ninja.
set -euo pipefail
cd "$(dirname "$0")/.."

BOARD=${BOARD:-mondrian}
case "$BOARD" in
	mondrian) SERIES=xnu/patches-mondrian; MACHINE=MONDRIAN ;;
	sweet)    SERIES=xnu/patches;          MACHINE=SWEET ;;
	*) echo "error: unknown BOARD '$BOARD'" >&2; exit 1 ;;
esac
DXB_DIR=${DXB_DIR:-/private/tmp/dxblocal}
DXB_REPO=${DXB_REPO:-https://github.com/blacktop/darwin-xnu-build}
DXB_SHA=${DXB_SHA:-663906528d1cd5ea8fde7de6f16de73db9511549}
MACOS_VERSION=${MACOS_VERSION:-13.5}
KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT}
LOG=${LOG:-/tmp/kernel-local.log}
# A KDK already on disk is used as is; that keeps the build from installing
# one (the installer wants root). tools/get-kdk.sh fetches it.
KDKROOT=${KDKROOT:-$(ls -d /private/tmp/kdk/root/*.kdk 2>/dev/null | head -1)}

for t in jq cmake ninja; do
	command -v "$t" >/dev/null || {
		echo "error: falta $t (brew install $t)" >&2
		exit 1
	}
done
# build.sh insists on these being present even when it does not use them
mkdir -p /tmp/dxsbin
for t in gum xcodes; do
	if ! command -v "$t" >/dev/null; then
		printf '#!/bin/sh\nexit 0\n' > "/tmp/dxsbin/$t"
		chmod +x "/tmp/dxsbin/$t"
	fi
done
export PATH=/tmp/dxsbin:$PATH

if [ -f "$DXB_DIR/build.sh" ] && [ -d "$DXB_DIR/patches" ]; then
	echo "== using the dxb checkout at $DXB_DIR"
else
	if [ -d "$DXB_DIR" ] && [ -n "$(ls -A "$DXB_DIR" 2>/dev/null)" ]; then
		echo "error: $DXB_DIR exists and is not a dxb checkout (no build.sh);" >&2
		echo "       point DXB_DIR at an empty directory" >&2
		exit 1
	fi
	echo "== fetching dxb ($DXB_SHA)"
	mkdir -p "$DXB_DIR"
	git init -q "$DXB_DIR"
	git -C "$DXB_DIR" fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA"
	git -C "$DXB_DIR" checkout -qf FETCH_HEAD
fi

echo "== copying the $BOARD series into $DXB_DIR/patches"
mkdir -p "$DXB_DIR/patches"
cp "$SERIES"/*.patch "$DXB_DIR/patches/"
cp "$SERIES"/*.sh "$DXB_DIR/patches/" 2>/dev/null || true
# plain arm64 for libfirehose (idempotent)
sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' "$DXB_DIR/build.sh"
grep -q 'VALID_ARCHS="x86_64 arm64e arm64"' "$DXB_DIR/build.sh" || {
	echo "error: build.sh did not take the ARCHS change" >&2
	exit 1
}

if [ -d "$DXB_DIR/xnu/.git" ] &&
	git -C "$DXB_DIR/xnu" rev-parse --verify -q HEAD >/dev/null; then
	echo "== resetting the xnu checkout"
	git -C "$DXB_DIR/xnu" reset -q --hard
	git -C "$DXB_DIR/xnu" clean -qfdx
elif [ -d "$DXB_DIR/xnu" ]; then
	# Without its own history, "git -C xnu" walks up to the dxb repo and the
	# clean would delete the whole kernel tree (that happened once).
	echo "warning: $DXB_DIR/xnu has no git HEAD; leaving it untouched" >&2
fi

# Xcode 16 and newer ship an iig that emits IORPC.kernelContent, a field this
# xnu (8796) does not have: the CI pins Xcode 15 for that reason. The generated
# DriverKit stubs do not depend on the kernel config, so a RELEASE build reuses
# the ones a DEVELOPMENT build already generated instead of re-running iig.
if [ "$KERNEL_CONFIG" = RELEASE ]; then
	DEV="$DXB_DIR/build/xnu.obj/DEVELOPMENT_ARM64_${MACHINE}/iokit/DEVELOPMENT/DriverKit"
	if [ -d "$DEV" ]; then
		for REL in \
			"$DXB_DIR/build/xnu.obj/RELEASE_ARM64_${MACHINE}/iokit/RELEASE/DriverKit" \
			"$DXB_DIR/build/xnu.obj/RELEASE_ARM64_${MACHINE}/iokit/DriverKit"; do
			mkdir -p "$REL"
			cp "$DEV"/*.h "$DEV"/*.iig.cpp "$REL"/
			touch "$REL"/*	# newer than the .iig sources: make does not rerun iig
		done
		echo "== seeded the RELEASE DriverKit stubs from DEVELOPMENT"
	else
		echo "error: a RELEASE build needs the iig stubs from a DEVELOPMENT" >&2
		echo "       build first (Xcode 16+ iig does not match xnu-8796)" >&2
		exit 1
	fi
fi

# build.sh skips the kernel when this marker exists (it only asks whether the
# file is there, not whether it is current), so drop it and keep a stamp: the
# kernel has to be newer than the stamp or the build did nothing.
KT="$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]').$(echo "$MACHINE" | tr '[:upper:]' '[:lower:]')"
rm -f "$DXB_DIR/build/xnu.obj/kernel.$KT"
STAMP=/tmp/.kernel-local.stamp
: > "$STAMP"

echo "== building $KERNEL_CONFIG $MACHINE (log: $LOG)"
( cd "$DXB_DIR" && KDKROOT="$KDKROOT" MACHINE_CONFIG="$MACHINE" \
    MACOS_VERSION="$MACOS_VERSION" KERNEL_CONFIG="$KERNEL_CONFIG" \
    MAKEFLAGS=-k bash build.sh ) >"$LOG" 2>&1 || true

if grep -E 'Skipping patch .*/patches/[0-9]{4}-' "$LOG"; then
	echo "error: a patch did not apply; the kernel would miss it" >&2
	exit 1
fi

# The kernel is kernel.<config>.<machine>; a glob such as kernel.*development
# matches nothing (the name continues), and the failing assignment aborted the
# script before the copy.
KERNEL="$DXB_DIR/build/xnu.obj/${KERNEL_CONFIG}_ARM64_${MACHINE}/kernel.$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]').$(echo "$MACHINE" | tr '[:upper:]' '[:lower:]')"
if [ ! -f "$KERNEL" ] || [ ! "$KERNEL" -nt "$STAMP" ]; then
	echo "error: no kernel built in this run; the tail of $LOG:" >&2
	grep -E "error:" "$LOG" | grep -v "does not apply" | tail -15 >&2
	exit 1
fi
cp "$KERNEL" /tmp/kernel."$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]')".mondrian
echo "== $KERNEL"
shasum -a 256 /tmp/kernel."$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]')".mondrian
