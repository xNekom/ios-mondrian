# Building the kernel without a Mac

XNU cannot be compiled natively on Windows: the kernel is a Mach-O image, and
the link needs Apple's `ld64` (`-image_base`, `-segaddr`, `-segment_order`,
`-alias_list`), Apple's `mig`, Xcode's `iig` for the DriverKit stubs, and the
macOS SDK headers. This document is the local, Mac-free path: **WSL2 + a Linux
Mach-O toolchain**. Two other paths exist and are not described here: the CI
(`.github/workflows/xnu.yml`) which needs no local toolchain at all, and
`tools/build-kernel-local.sh` on the macOS machine, which stays the reference
build.

Everything lives under `tools/wsl/`; the patch series and the staging scripts
are the same ones the Mac and the CI use, untouched.

## One-time setup

In PowerShell (once per machine):

```powershell
wsl --install -d Ubuntu-24.04
```

In the Ubuntu shell, from the repository root:

```sh
sudo tools/wsl/apt-deps.sh          # clang, llvm, cmake, ninja, flex, bison, tcsh, ruby, libbsd
tools/wsl/bootstrap-toolchain.sh    # ~10 minutes, installs ~/.local/xnu-linux
```

`bootstrap-toolchain.sh` builds and pins (`~/.local/xnu-linux/versions.txt`):

| component | what it is for |
| --- | --- |
| cctools-port `ld64` | the kernel link; `ld64.lld` implements none of the six XNU-specific options |
| cctools `ar`/`strip`/`nm`/`otool`/`lipo` | GNU `ar` archives are rejected by `ld64`, which then drops the whole `.a` silently |
| `mig`/`migcom` (`bootstrap_cmds`, `cross_platform`) | Mach interface generation (it is not in cctools) |
| `iig` (Python) | DriverKit stub generator, replaces Xcode's |
| `xcrun`, `plutil`, `codesign`, `ditto`, `sw_vers` | shims for the tools xnu's makefiles call |
| `libhostcompat` | BSD calls the build-time tools need (`setmode`, `fcopyfile`, `swap_*`) |

The WSL2 checkout must be LF, or every `set -euo pipefail` fails with
`invalid option name` and no patch applies: `.gitattributes` pins `eol=lf`, so
a fresh clone is correct. On an existing checkout run `git config core.autocrlf
false && git rm -r --cached . -q && git reset --hard` once.

## Building

```sh
tools/wsl/build-kernel.sh                  # DEVELOPMENT, mondrian
KERNEL_CONFIG=RELEASE tools/wsl/build-kernel.sh
BOARD=sweet tools/wsl/build-kernel.sh
STAGE=hdrs tools/wsl/build-kernel.sh       # stop after make installhdrs
WORK=~/xnu-build tools/wsl/build-kernel.sh # move the tree and the fakeroot
```

The script fetches `xnu-8796.141.3`, resets the tree, runs the staging scripts
(libpthread, BearSSL, HFS), applies every patch of the board's series (182 for
mondrian, 81 for sweet) plus `tools/wsl/patches/`, assembles the fakeroot, runs
`make installhdrs`, builds `libfirehose_kernel.a` and then `make install`. The
kernel lands in `xnu/out/kernel.development.<board>`; the full log in
`xnu/out/kernel-linux.log`. A patch that does not apply stops the build instead
of producing a kernel missing it, which is the failure mode CI had with `0161`.

Caches (the xnu tree, the fakeroot, the object directory) live in
`~/.cache/ios-mondrian/xnu-linux`. Deleting `fakeroot/` forces a fresh
`installhdrs`.

## What replaces what

| macOS | here |
| --- | --- |
| Xcode SDK / KDK | a fakeroot: `SDKROOT_RESOLVED` and `DSTROOT` are the same tree, filled by `installhdrs` |
| Xcode clang | host clang with `-target <arch>-apple-macos13.5` (`arm64` on these boards); `--ld-path` points the driver at cctools' `ld64` |
| SDK `usr/local/include/kernel`, `Kernel.framework` | `$FAKEROOT/usr/local/include/kernel`, `$FAKEROOT/System/Library/Frameworks/Kernel.framework` |
| `availability.pl` (AvailabilityVersions) | built from the same `macos-135` release as the xnu tag |
| libplatform headers | copied into `$FAKEROOT/usr/local/include` |
| `xcodebuild` for libfirehose | `tools/wsl/build-firehose.sh`: the one file the Xcode target compiles, plus two `mig` outputs |
| DTrace CTF tools | absent; xnu turns `DO_CTFMERGE` off when `ctfmerge` cannot be found, as in the CI kernel |

The kernel is compiled with `PLATFORM=MacOSX` and `XNU_TARGET_OS_OSX`, exactly
like the CI kernel, because the series is validated against that platform. The
page size (16 KiB on both boards) and the arch string (plain `arm64`: these
cores have no pointer authentication) come from the board's patch, not from the
host.

## Linux-specific code

- `tools/wsl/patches/0001-linux-host-tools.patch` — `XCRUN`, `PLUTIL`, `PAX`
  and `HOST_CODESIGN` are hardcoded `/usr/bin` paths in `MakeInc.cmd`; `?=`
  lets the shims be used. macOS sees the same values.
- `tools/wsl/sdk/usr/include/TargetConditionals.h` — the kernel includes it
  from `osfmk/mach/message.h` and `OSMetaClass.h`. 938 uses of
  `TARGET_OS_OSX` mean a missing definition would silently select other code
  (an undefined macro is 0 in `#if`), so the values match the macOS build.
- `tools/wsl/shim/target-clang`, `host-clang` — the kernel target and the
  build-time tools (ELF) need different treatment: the kernel is told apart by
  its `-arch` flag and gets a Darwin target, the host tools lose `-isysroot`,
  `-mmacosx-version-min` and friends.
- `tools/wsl/build-firehose.sh` — builds `libfirehose_kernel.a` the way the
  Xcode target does: `mig` on `firehose.defs` (client) and `firehose_reply.defs`
  (server), then `firehose_buffer.c`. `os/firehose_buffer_private.h` is guarded
  by `#if OS_FIREHOSE_SPI`, so the installed copy in the fakeroot defines it;
  libdispatch compiles with that define and the kernel includes the same header.
- `tools/wsl/patches/0002-linux-kalloc-builtins.patch` —
  `__builtin_xnu_type_summary`/`_signature`/`_types_compatible` are Apple clang
  extensions for `kalloc_type`. Upstream clang has none of them, so the fallback
  reports data-only batches: the static asserts hold and the type-metadata fast
  paths (and their runtime checks) are gone.
- `tools/wsl/patches/0003-linux-crypto-asm-syntax.patch` — the SHA/AES macros in
  `arm64_isa_compatibility.h` use `qN` register names unless
  `__apple_build_version__` is new enough; upstream clang does not define it and
  its assembler rejects `sha256su0 q0, q1`.
- `tools/wsl/patches/0004-linux-link-shims.patch` — `bsd/pgo/profile_runtime.c`
  and libkern's C++ bootstrap reference Apple's compiler-rt profile helpers and
  `__cxa_atexit`; `osfmk/vm/vm_link_compat.c` provides empty versions.
- `tools/wsl/patches/0005-linux-iig-forwarders.patch` — the DriverKit forwarder
  `IOUserClient::CreateActionKernelCompletion` is emitted by Apple's `iig` into
  the generated `.iig.cpp`, which the Linux `iig` leaves as a declaration.
- `tools/wsl/patches/0006-linux-skip-symbolsets.patch` — the symbolset and
  export/import check compares the kernel's symbol table with Apple's `.exports`
  lists; the Linux `iig` emits a different set of DriverKit `_Invoke` overloads
  and OSAction subclasses, so the check cannot pass. Symbol sets only feed kext
  linking, so the build takes the branch xnu already has for library builds.

## Verifying a build

```sh
file xnu/out/kernel.development.<board>           # Mach-O 64-bit arm64
"$HOME/.local/xnu-linux/cctools/bin/otool" -l xnu/out/kernel.development.<board> | head -40
grep -c 'Skipping patch' xnu/out/kernel-linux.log # must be 0
```

`__TEXT` must sit at the kernel link address for this platform
(`0xfffffe0007004000` with `PLATFORM=MacOSX` and `ARM_LARGE_MEMORY`, as the
`otool -l` output of a good build shows; the embedded layout uses
`0xfffffff007004000`) and the segments must appear in
`__TEXT:__DATA_CONST:__TEXT_EXEC:__KLD:...:__BOOTDATA` order; `otool -h` must
report `NOUNDEFS`. A kernel linked by `ld64.lld` would sit at `__TEXT` 0 with
every vtable slot off by 2^52, which prelink and kext binding then reject.

## Known gaps

- The `iig` shim generates the DriverKit macros and forwarders, but its
  `*_Invoke` bodies are stubs. That does not affect this kernel: the DriverKit
  RPC path is not used on these boards.
- No CTF section (DTrace type data), same as the kernel the CI links.
- No kext symbol sets and no export/import check (see `0006`). A kernel-only
  build does not consume them; the kernel link itself still uses
  `all-kpi.exp` and `all-alias.exp`, which are generated as before.
- No kexts: the build produces the monolithic kernel only.
- The `iig` implementation is fetched at a pinned commit from
  `Allenwdk/xnu-linux-toolchain` (`tools/wsl/bootstrap-toolchain.sh`); the
  rest of the toolchain is built from Apple's and Fabian/tpoechtrager's trees.
- A **mondrian** build from a clean tree stops in `bsd/dev/mondrian_gpu.c`:
  the firmware loop added by `0177` uses `mondrian_gmu_blocks` without the
  `#ifdef MONDRIAN_GMU_FW` guard the same patch uses elsewhere, and the array
  only exists in `bsd/dev/mondrian_gmu_fw.h`, which `tools/gen-gmu-fw.py`
  generates from the phone's GMU blob. Either generate that header or guard
  the loop. Nothing about it is Linux-specific: the macOS build and the CI hit
  the same error.

## When it breaks

| symptom | cause and fix |
| --- | --- |
| `set: invalid option name` | CRLF working tree; see the LF note above |
| `xcrun: unable to find utility` | `$PREFIX` is stale; re-run `bootstrap-toolchain.sh` |
| `cannot find -lhostcompat` | same: the shims are copied on every bootstrap run |
| `Skipping patch .../00NN-` | the series does not apply to the pinned xnu tag; run `tools/apply-series.py` |
| kernel built but wrong page size | the board's `0001` patch and `tools/boards.py` disagree |
