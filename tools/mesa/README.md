# Mesa for mondrian

Mesa 25.0.7 for the iOS 16 arm64 userland, with freedreno's msm back end driven
through the kernel's `MondrianGPU` service instead of Linux's DRM. Untested on
hardware: the dylib builds and links, no frame has been rendered with it.

- `mondrian-drm/` — the libdrm Mesa's freedreno is built against here.
  `drmOpenWithType("msm")` opens `MondrianGPU` and one request is one
  `IOConnectCallStructMethod` whose selector is the low byte of the ioctl code,
  with Linux's `include/uapi/drm/msm_drm.h` structures unchanged both ways. A
  buffer's memory is mapped by its GEM handle (`mondrian_drm_map`, the stand-in
  for `mmap`); `drmGetVersion` reports 1.7/"msm", the softpin-era interface the
  kernel implements.
- `mondrian-darwin.patch` — the Mesa edits: `dep_libdrm` replaced by the shim,
  `src/freedreno/drm` built on Darwin, buffers mapped and unmapped through it,
  no shader disk cache (a Mach-O library has no build id), and OSMesa able to
  create the GPU's screen instead of only the software one.

## Build

```
tools/mk-mesa-ios.sh                              # fetches Mesa 25.0.7
MESA=/path/to/mesa-25.0.7 tools/mk-mesa-ios.sh    # a tree instead; patched in place
```

Needs Xcode with the iphoneos SDK, ninja, python3 and GNU bison 3 (`brew
install bison`; the script puts `/opt/homebrew/opt/bison/bin` first). It makes
its own meson venv, so no global meson is needed. A `MESA=` tree is edited in
place, so point it at a scratch checkout.

The result is in `out/mesa/stage/`: `libOSMesa.8.dylib` (ad-hoc signed,
install name `/usr/lib/libOSMesa.8.dylib`), `gl.xml` (Mesa's GL registry, for
entry point lookup) and `exported-gl.txt` (the `gl*` symbols it exports).
`out/mesa/` also holds the source, the venv, `cross.ini` and the logs, and is
gitignored.

At runtime the dylib creates the freedreno screen from `MondrianGPU` and falls
back to softpipe when that fails (`OSMESA_SOFTWARE=1` forces the fallback).

## What is missing

- **Relocations.** `GEM_SUBMIT` refuses `nr_relocs != 0`; freedreno's msm back
  end uses softpin (`GEM_INFO` GET/SET_IOVA) for every command buffer, so
  nothing this build sends carries one, and nothing imported can be placed.
- **Syncobjs and prime fds.** `drmSyncobj*`, `drmPrimeFDToHandle` and
  `drmPrimeHandleToFD` return `ENOSYS`, and `drmGetCap` reports no capability:
  freedreno waits on the fence the kernel returns (`WAIT_FENCE`), and no buffer
  is shared with another process.
- **Cache visibility.** freedreno asks for write-combined buffers (`MSM_BO_WC`)
  and expects its writes to be in the GPU's view; the buffer is the kernel's
  `IOBufferMemoryDescriptor`, so that stays the kernel's to guarantee, untested.
- **Presentation.** There is no `IOSurface` request (0x7e), so a frame stays in
  the context's own buffers and cannot be handed to a window server;
  `mondrian_drm.c` marks the calls the surface path replaces.

## Kernel side

`iokit/Kernel/arm/MondrianGPU.cpp` (patches 0181, 0182) with the bring-up in
`bsd/dev/mondrian_gpu.c`; state and traps in
[`docs/MONDIAN_GPU.md`](../../docs/MONDIAN_GPU.md).
