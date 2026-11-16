#!/bin/bash
# Stage the series in a scratch tree so a patch can be regenerated from a diff
# against exactly what precedes it.
#
#   tools/wsl/series-stage.sh [last-patch-prefix] [dir]
#
# Defaults to 0339 into /root/series-0339. The tree is a copy of the pristine XNU
# cache (research/xnu-src-8796), so git apply and git diff both work and nothing
# in research/ is touched. This is the tree the 00NN patch builders diff against;
# diffing against the build cache instead duplicates whatever the last build
# already applied (that is how 0341 stopped applying). It lives under /root
# because /tmp is scrubbed between WSL sessions here.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1

LAST=${1:-0339}
DIR=${2:-/root/series-${LAST}}
SEEN=$(realpath research/xnu-src-8796) || exit 1

rm -rf "$DIR"
mkdir -p "$DIR"
tar -C "$SEEN" -cf - . | tar -C "$DIR" -xf -
cd "$DIR" || exit 1
git init -q 2>/dev/null || true

# Some patches modify sources the stage scripts copy in (libpthread, BearSSL,
# HFS); without them 0036 and friends cannot apply. A stage script that needs a
# macOS toolchain fails on Linux without hurting the patches staged here, so the
# failure is reported and the loop continues (check-patches.sh does the same).
for s in "$OLDPWD"/xnu/patches-mondrian/*.sh; do
	[ -f "$s" ] || continue
	MACHINE_CONFIG=${MACHINE_CONFIG:-MONDRIAN} MACOS_VERSION=13.5 \
		bash "$s" > /tmp/series-stage.log 2>&1 || \
		echo "stage $(basename "$s") failed (see /tmp/series-stage.log)"
done

n=0
for p in "$OLDPWD"/xnu/patches-mondrian/*.patch; do
	base=$(basename "$p")
	[ "${base%%-*}" \> "$LAST" ] && break
	git apply --whitespace=nowarn "$p" || { echo "FAIL $base" >&2; exit 1; }
	n=$((n + 1))
done
git add -A 2>/dev/null || true
git -c user.email=stage@local -c user.name=stage commit -qm "series up to $LAST" 2>/dev/null || true
echo "$n patches applied in $DIR (last $LAST)"
