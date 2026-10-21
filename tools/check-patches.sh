#!/bin/sh
# Apply a patch series to a pristine XNU, locally, before spending a CI run.
#
# The kernel is built in CI, but a patch that does not apply is *skipped with a
# warning* and the build still succeeds: the kernel then silently lacks that
# feature. That is how 0010 (the early framebuffer) was lost on 2026-10-21, and
# it cost a ten minute round trip to find out. This takes ten seconds.
#
#   tools/check-patches.sh                 # xnu/patches-mondrian (mondrian)
#   tools/check-patches.sh xnu/patches     # the sweet series
#   NO_STAGE=1 tools/check-patches.sh      # skip the 00XX-stage-*.sh scripts
#
# The pristine tree is cached in research/ (not in git), so the download
# happens once. XNU_SRC=/path/to/tree uses a tree instead of the cache.
#
# Exit status: 0 every patch applies, 1 something does not.
set -u

SERIES=${1:-xnu/patches-mondrian}
TAG=xnu-8796.141.3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CACHE="$ROOT/research/xnu-src-8796"
TARBALL="$ROOT/research/$TAG.tar.gz"

cd "$ROOT" || exit 1
[ -d "$SERIES" ] || { echo "no such series: $SERIES" >&2; exit 2; }

if [ -n "${XNU_SRC:-}" ]; then
	SRC=$XNU_SRC
else
	if [ ! -d "$CACHE/.git" ]; then
		echo "fetching $TAG (once, into research/)"
		mkdir -p research
		[ -f "$TARBALL" ] || curl -sSL -o "$TARBALL" \
			"https://github.com/apple-oss-distributions/xnu/archive/refs/tags/$TAG.tar.gz" || exit 2
		rm -rf "$CACHE" "$CACHE.tmp"
		mkdir -p "$CACHE.tmp"
		tar xzf "$TARBALL" -C "$CACHE.tmp" || exit 2
		mv "$CACHE.tmp/xnu-$TAG" "$CACHE" || exit 2
		rmdir "$CACHE.tmp"
		git -C "$CACHE" init -q || exit 2
		git -C "$CACHE" add -A || exit 2
		git -C "$CACHE" -c user.email=check@local -c user.name=check \
			commit -qm "pristine $TAG" || exit 2
	fi
	# A scratch copy per run: git apply is one way, re-cloning is the easy reset.
	# -c is APFS clonefile, so this is cheap.
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/xnu-check.XXXXXX") || exit 2
	trap 'rm -rf "$WORK"' EXIT
	cp -Rc "$CACHE" "$WORK/xnu" 2>/dev/null || cp -R "$CACHE" "$WORK/xnu" || exit 2
	SRC="$WORK/xnu"
fi

cd "$SRC" || exit 1

if [ "${NO_STAGE:-0}" != 1 ]; then
	# dxb runs patches/*.sh from the XNU root before the patches: they stage
	# Apple's open-source sources (libpthread, BearSSL, HFS) that some patches
	# then modify. Same order as CI.
	for s in "$ROOT/$SERIES"/*.sh; do
		[ -f "$s" ] || continue
		printf 'stage %s ... ' "$(basename "$s")"
		if MACHINE_CONFIG=${MACHINE_CONFIG:-MONDRIAN} MACOS_VERSION=13.5 \
			bash "$s" >/tmp/xnu-check-stage.log 2>&1; then
			echo ok
		else
			echo "FAILED (see /tmp/xnu-check-stage.log)"
		fi
	done
fi

fails=0
total=0
for p in "$ROOT/$SERIES"/*.patch; do
	[ -f "$p" ] || continue
	total=$((total + 1))
	if out=$(git apply --whitespace=nowarn "$p" 2>&1); then
		continue
	fi
	fails=$((fails + 1))
	echo "FAIL $(basename "$p")"
	echo "$out" | sed 's/^/     /'
done

echo "---"
echo "$((total - fails))/$total patches apply"
if [ "$fails" -ne 0 ]; then
	echo "CI would skip the ones above and still build a kernel. Fix them first."
	exit 1
fi
