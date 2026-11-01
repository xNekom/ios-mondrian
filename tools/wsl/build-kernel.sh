#!/usr/bin/env bash
# Build the mondrian (or sweet) XNU kernel on Linux/WSL2 — no Mac, no Xcode.
#
#   tools/wsl/build-kernel.sh                 # DEVELOPMENT for mondrian
#   KERNEL_CONFIG=RELEASE tools/wsl/build-kernel.sh
#   BOARD=sweet tools/wsl/build-kernel.sh
#   STAGE=hdrs tools/wsl/build-kernel.sh      # stop after make installhdrs
#   WORK=~/xnu-build tools/wsl/build-kernel.sh
#
# The pieces the Mac has and Linux does not are replaced like this:
#
#   Xcode SDK / KDK            -> a fakeroot: xnu's own installhdrs fills it,
#                                 so SDKROOT and DSTROOT are the same tree
#   Xcode clang                -> host clang, but always launched with
#                                 -target arm64-apple-macos13.5 (target-clang)
#   Apple ld64                 -> cctools-port's ld64 (ld64.lld cannot link an
#                                 XNU kernel: no -image_base/-segaddr/...)
#   mig                        -> bootstrap_cmds cross_platform
#   iig (DriverKit)            -> Python reimplementation
#   plutil/codesign/ditto/...  -> shims
#   libdispatch firehose       -> its headers are copied into the fakeroot and
#                                 the archive is a stub (see docs/BUILD_LINUX.md)
#
# The result is the same Mach-O the macOS runner produces; the toolchain it
# needs is built once by tools/wsl/bootstrap-toolchain.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

BOARD=${BOARD:-mondrian}
case "$BOARD" in
	mondrian) SERIES=xnu/patches-mondrian MACHINE=MONDRIAN ;;
	sweet) SERIES=xnu/patches MACHINE=SWEET ;;
	*) echo "error: unknown BOARD '$BOARD'" >&2; exit 1 ;;
esac
XNU_TAG=${XNU_TAG:-xnu-8796.141.3}
MACOS_VERSION=${MACOS_VERSION:-13.5}
# Apple's release.json names the source tag of every project in a macOS release;
# the staging scripts and availability.pl/libplatform must come from the same
# release as the xnu tag, so the tags are read from it instead of hardcoded.
RELEASE_URL=${RELEASE_URL:-https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-135/release.json}
RC_RELEASE=${RC_RELEASE:-22.6.0}
KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT}
MACHINE=${MACHINE_CONFIG:-$MACHINE}
WORK=${WORK:-$HOME/.cache/ios-mondrian/xnu-linux}
STAGE=${STAGE:-all}
XNU=$WORK/xnu
FAKEROOT=$WORK/fakeroot
OBJROOT=$WORK/build/xnu.obj
SYMROOT=$WORK/build/xnu.sym
LOG=${LOG:-xnu/out/kernel-linux.log}
JOBS=${JOBS:-$(nproc)}
ADDITIONAL_SYMBOLS=${ADDITIONAL_SYMBOLS:-}

say() { echo "== $*"; }
die() { echo "error: $*" >&2; exit 1; }

# release_tag PROJECT -> the git tag that project has in this macOS release
release_tag() {
	[ -f "$WORK/release.json" ] || curl -fsSL "$RELEASE_URL" -o "$WORK/release.json" ||
		die "cannot fetch $RELEASE_URL"
	python3 - "$WORK/release.json" "$1" <<'PY'
import json, sys
for project in json.load(open(sys.argv[1]))["projects"]:
    if project["project"] == sys.argv[2]:
        print(project["tag"])
        break
else:
    sys.exit("no tag for " + sys.argv[2])
PY
}

# shellcheck source=tools/wsl/env.sh
. tools/wsl/env.sh

mkdir -p "$WORK" xnu/out

# The SDK is the fakeroot: xnu installs its headers into DSTROOT and compiles
# against `-I$(SDKROOT)/...` in the same build, so both must be the same tree.
# These four variables short-circuit every xcrun/plutil query in MakeInc.cmd.
export UNIXNU_SDKROOT="$FAKEROOT" UNIXNU_SDK_VERSION="$MACOS_VERSION"
export SDKROOT_RESOLVED="$FAKEROOT" HOST_SDKROOT_RESOLVED="$FAKEROOT"
export SDKVERSION="$MACOS_VERSION" HOST_OS_VERSION="$MACOS_VERSION" PLATFORM=MacOSX


# ------------------------------------------------------------------ 1. the tree
# Re-applying the series rewrites the mtime of every file they touch and makes
# the next build a full rebuild, so the tree is only reset when the series (or
# the tree itself) changed since the last run.
SERIES_STATE=$WORK/.series-state
SERIES_HASH=$(
	cat "$SERIES"/*.patch tools/wsl/patches/*.patch 2>/dev/null |
		sha256sum | cut -d' ' -f1
)

if [ ! -d "$XNU/.git" ]; then
	say "fetching $XNU_TAG"
	mkdir -p "$XNU"
	git -C "$XNU" init -q
	git -C "$XNU" fetch -q --depth 1 https://github.com/apple-oss-distributions/xnu.git "refs/tags/$XNU_TAG"
	git -C "$XNU" checkout -q FETCH_HEAD
elif [ -f "$SERIES_STATE" ] && [ "$(cat "$SERIES_STATE")" = "$SERIES_HASH" ] &&
	git -C "$XNU" rev-parse -q --verify HEAD >/dev/null; then
	say "the tree already carries this series; reuse it"
	SKIP_SERIES=1
fi
git -C "$XNU" describe --tags --always

# The fakeroot is the stand-in for the Xcode SDK: xnu's installhdrs fills it
# and the kernel compiles against the same tree (SDKROOT_RESOLVED = DSTROOT).
mkdir -p "$FAKEROOT/usr/local/include/kernel" "$FAKEROOT/usr/local/libexec" \
	"$FAKEROOT/usr/local/lib/kernel" "$FAKEROOT/usr/include" "$OBJROOT" "$SYMROOT"

# <TargetConditionals.h> is an SDK header the kernel includes from
# osfmk/mach/message.h and OSMetaClass.h; there is no macOS SDK on Linux, so
# the fakeroot carries our copy (tools/wsl/sdk). Both paths: the kernel finds
# headers through -I$(SDKROOT)/usr/local/include/kernel, and the staging scripts
# look in $SDKROOT/usr/include.
for h in "$FAKEROOT/usr/local/include/kernel" "$FAKEROOT/usr/include"; do
	[ -f "$h/TargetConditionals.h" ] ||
		cp tools/wsl/sdk/usr/include/TargetConditionals.h "$h/"
done

# ------------------------------------------------------ 2. series + staging scripts
# The staging scripts copy libpthread, BearSSL and hfs into the tree; they are
# pinned to immutable commits and bail out if MACHINE_CONFIG/MACOS_VERSION do
# not match the xnu generation.
if [ "${SKIP_SERIES:-0}" != 1 ]; then
	# A build must start from the tag, not from the previous build's tree: the
	# series has to apply cleanly or a patch is silently lost.
	say "resetting $XNU"
	git -C "$XNU" reset -q --hard
	git -C "$XNU" clean -qfdx

	for s in "$SERIES"/*.sh; do
		[ -e "$s" ] || continue
		say "staging $(basename "$s")"
		( cd "$XNU" && MACHINE_CONFIG="$MACHINE" MACOS_VERSION="$MACOS_VERSION" bash "$OLDPWD/$s" )
	done

	say "applying $SERIES ($(ls "$SERIES"/*.patch | wc -l) patches)"
	for p in "$SERIES"/*.patch; do
		git -C "$XNU" apply --whitespace=nowarn "$OLDPWD/$p" ||
			die "$(basename "$p") does not apply; the kernel would be missing it"
	done

	# The portability patches are ours (rebased on this xnu tag); the series
	# above is the project's and never changes for Linux.
	if compgen -G "tools/wsl/patches/*.patch" >/dev/null; then
		say "applying tools/wsl/patches"
		for p in tools/wsl/patches/*.patch; do
			git -C "$XNU" apply --whitespace=nowarn "$PWD/$p" ||
				die "$(basename "$p") does not apply to $XNU_TAG"
		done
	fi
	printf '%s\n' "$SERIES_HASH" >"$SERIES_STATE"
fi

# Local inputs that are not in git (the GMU blob, the SQE/ZAP firmware, the CP
# profile) generate *_fw.h / *_profile.h. A series change resets the tree, so
# install them after it; $WORK/local survives resets and holds the headers
# between builds.
if [ -d "$WORK/local" ]; then
	for h in "$WORK/local"/*.h; do
		[ -e "$h" ] || continue
		say "installing local header $(basename "$h")"
		cp -f "$h" "$XNU/bsd/dev/"
	done
fi
if [ "$BOARD" = mondrian ] && [ ! -f "$XNU/bsd/dev/mondrian_gmu_fw.h" ]; then
	die "no mondrian_gmu_fw.h; generate it from gmu_gen70000.bin (tools/gen-gmu-fw.py) and put it in $WORK/local"
fi
if [ "$BOARD" = mondrian ] && [ ! -f "$XNU/bsd/dev/mondrian_cp_profile.h" ]; then
	say "no mondrian_cp_profile.h: the CP path and the GPU user client stay inert"
fi

# ----------------------------------------------------------------- 3. the fakeroot
# Everything xnu compiles against lives here.

# availability.pl turns @available() attributes into symbol aliases; xnu looks
# for it at $SDKROOT/usr/local/libexec (DRIVERKITROOT is empty here).
if [ ! -x "$FAKEROOT/usr/local/libexec/availability.pl" ]; then
	AV_TAG=$(release_tag AvailabilityVersions) || exit 1
	say "installing availability.pl ($AV_TAG)"
	AV=$WORK/src/AvailabilityVersions
	mkdir -p "$AV"
	git -C "$AV" init -q 2>/dev/null || true
	git -C "$AV" fetch -q --depth 1 https://github.com/apple-oss-distributions/AvailabilityVersions.git \
		"refs/tags/$AV_TAG" || die "cannot fetch $AV_TAG"
	git -C "$AV" checkout -qf FETCH_HEAD
	( cd "$AV" && make -s install DSTROOT="$FAKEROOT" OBJROOT="$WORK/build/av.obj" SYMROOT="$WORK/build/av.sym" )
fi

# libplatform ships the os/ private headers the kernel includes from
# $SDKROOT/usr/local/include.
if [ ! -f "$FAKEROOT/usr/local/include/_simple.h" ]; then
	LP_TAG=$(release_tag libplatform) || exit 1
	say "installing libplatform headers ($LP_TAG)"
	LP=$WORK/src/libplatform
	mkdir -p "$LP"
	git -C "$LP" init -q 2>/dev/null || true
	git -C "$LP" fetch -q --depth 1 https://github.com/apple-oss-distributions/libplatform.git \
		"refs/tags/$LP_TAG" || die "cannot fetch $LP_TAG"
	git -C "$LP" checkout -qf FETCH_HEAD
	cp -R "$LP/include/." "$FAKEROOT/usr/local/include/"
	cp -R "$LP/private/." "$FAKEROOT/usr/local/include/"
fi

# libfirehose_kernel: the os_log firehose staging buffer. The headers xnu
# includes from it (os/firehose_buffer_private.h) are installed by libdispatch
# into $SDKROOT/usr/local/include/kernel/os in a macOS build; copy them here.
# The archive itself is built after installhdrs (it needs Kernel.framework).
if [ ! -d "$WORK/src/libdispatch/os" ]; then
	LD_TAG=$(release_tag libdispatch) || exit 1
	say "fetching libdispatch ($LD_TAG)"
	LD=$WORK/src/libdispatch
	mkdir -p "$LD"
	git -C "$LD" init -q 2>/dev/null || true
	git -C "$LD" fetch -q --depth 1 https://github.com/apple-oss-distributions/libdispatch.git \
		"refs/tags/$LD_TAG" || die "cannot fetch $LD_TAG"
	git -C "$LD" checkout -qf FETCH_HEAD
fi
mkdir -p "$FAKEROOT/usr/local/include/kernel/os"
# firehose_buffer_private.h is guarded by `#if OS_FIREHOSE_SPI` and libdispatch
# builds it with that define; the kernel includes the same file (os/log.c), so
# the installed copy carries the define. Without it the whole header is empty
# and every firehose identifier is undeclared.
{
	echo '/* installed for the kernel build: see tools/wsl/build-kernel.sh */'
	echo '#define OS_FIREHOSE_SPI 1'
	cat "$WORK/src/libdispatch/os/firehose_buffer_private.h"
} >"$FAKEROOT/usr/local/include/kernel/os/firehose_buffer_private.h"

# ---------------------------------------------------------------- 4. xnu headers
# installhdrs builds the SETUP host tools (ELF, compiled by host-clang), runs
# mig and iig, and writes Kernel.framework + usr/local/include into DSTROOT.
mk() {
	( cd "$XNU" && make "$@" \
		SDKROOT=macosx TARGET_CONFIGS="$KERNEL_CONFIG ARM64 $MACHINE" \
		CONCISE=0 BUILD_WERROR=0 BUILD_LTO=0 \
		SRCROOT="$XNU" OBJROOT="$OBJROOT" SYMROOT="$SYMROOT" DSTROOT="$FAKEROOT" \
		RC_DARWIN_KERNEL_VERSION="$RC_RELEASE" \
		MEMORY_SIZE=17179869184 SYSCTL_HW_PHYSICALCPU="$JOBS" SYSCTL_HW_LOGICALCPU="$JOBS" \
		KERNEL_BUILDS_IN_PARALLEL=1 HOST_OS_VERSION="$MACOS_VERSION" \
		ADDITIONAL_SYMBOLS="$ADDITIONAL_SYMBOLS" XNU_SKIP_SYMBOLSETS=1 )
}

say "building $KERNEL_CONFIG $MACHINE on $XNU_TAG (log: $LOG)"
{
	say "make installhdrs"
	mk installhdrs ARCH_CONFIGS="ARM64" -j"$JOBS"
	# libfirehose_kernel.a compiles one libdispatch file against the headers
	# installhdrs just installed; it has to exist before the kernel links.
	say "building libfirehose_kernel.a"
	LD="$WORK/src/libdispatch" FAKEROOT="$FAKEROOT" XNU="$XNU" OUT="$WORK/build" \
		MIG="$UNIXNU_SHIM/mig" MIGCOM="$UNIXNU_SHIM/migcom" \
		CC="$UNIXNU_SHIM/target-clang" \
		bash tools/wsl/build-firehose.sh
	if [ "$STAGE" != hdrs ]; then
		say "make install"
		mk install -j"$JOBS"
	fi
} 2>&1 | tee "$LOG"
[ "${PIPESTATUS[0]}" = 0 ] || die "the build failed; tail of $LOG:
$(grep -E 'error:|Error [0-9]' "$LOG" | tail -20)"
if [ "$STAGE" = hdrs ]; then
	say "STAGE=hdrs: stopping after installhdrs"
	exit 0
fi

# ------------------------------------------------------------------- 5. the kernel
KERNEL="$OBJROOT/${KERNEL_CONFIG}_ARM64_${MACHINE}/kernel.$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]').$(echo "$MACHINE" | tr '[:upper:]' '[:lower:]')"
[ -f "$KERNEL" ] || die "no kernel built; tail of $LOG:
$(grep -E 'error:|Error ' "$LOG" | tail -20)"
OUT=xnu/out/kernel."$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]')"."$BOARD"
cp "$KERNEL" "$OUT"
say "$OUT"
file "$OUT"
sha256sum "$OUT"
