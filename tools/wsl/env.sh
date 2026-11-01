#!/usr/bin/env bash
# Environment for a Linux (WSL2) XNU build.  Source it, do not execute it:
#
#   source tools/wsl/env.sh
#   tools/wsl/build-kernel.sh
#
# It puts the Mach-O toolchain in front of the Linux one so that `ld`, `ar`,
# `strip`, `mig`, `iig`, `plutil` and `xcrun` resolve to the Darwin ones.
# Re-sourcing is safe.

XNU_LINUX_PREFIX=${XNU_LINUX_PREFIX:-$HOME/.local/xnu-linux}
case $- in *u*) _restore=1;; esac

if [ ! -x "$XNU_LINUX_PREFIX/bin/migcom" ] || [ ! -x "$XNU_LINUX_PREFIX/cctools/bin/ld" ]; then
	echo "env.sh: $XNU_LINUX_PREFIX is not a bootstrapped prefix" >&2
	echo "env.sh: run tools/wsl/bootstrap-toolchain.sh first" >&2
	[ -n "${_restore:-}" ] && set +u
	return 1 2>/dev/null || exit 1
fi

export XNU_LINUX_PREFIX
# shims first (xcrun/plutil/iig/mig), then cctools (ld64/ar/strip/otool/lipo)
export PATH="$XNU_LINUX_PREFIX/bin:$XNU_LINUX_PREFIX/cctools/bin:$PATH"

# the xcrun shim resolves tools under $UNIXNU_SHIM
export UNIXNU_SHIM="$XNU_LINUX_PREFIX/bin"
# <mach-o/*.h> and friends for the SETUP host tools (kextsymboltool,setsegname);
# cctools' `make install` does not ship its include tree
export UNIXNU_HOST_CCTOOLS_INCLUDE="$XNU_LINUX_PREFIX/cctools/include"

# the compiler the shims drive
export XNU_LINUX_CLANG=${XNU_LINUX_CLANG:-clang}
export JOBS=${JOBS:-$(nproc)}

# the kernel is built with BUILD_WERROR=0 (see tools/wsl/build-kernel.sh), so
# warnings are not errors here and no per-diagnostic downgrade list is needed

[ -n "${_restore:-}" ] && set -u && unset _restore
# bash caches where a command was found; without this a shell that already ran
# ld/clang keeps using the system ones after the PATH change above
hash -r 2>/dev/null || true
return 0 2>/dev/null || true
