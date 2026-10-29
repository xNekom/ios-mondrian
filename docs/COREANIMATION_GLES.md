# CoreAnimation on the GPU (OpenGL ES)

**Not yet run on hardware.** The UI is still the CPU rasterizer (`0114`) at 6.4 fps. This is the
userland half of step 4 in `docs/MONDIAN_GPU.md`; the kernel half is the `MondrianGPU` user client
(`0181`/`0182`). Everything here compiles for iOS 16 arm64 and nothing has been loaded on the phone.

## Who loads what

```
launchd -> /usr/libexec/backboardd
  DYLD_INSERT_LIBRARIES=/usr/libexec/mondrian-ui-hook.dylib     (0112, mondrian_ui_hook=2)
    load_gpu_test() in tools/mondrian-ui-hook.m                 (dlopen, constructor runs)
      /usr/libexec/mondrian-inject.dylib                        (tools/gpu/mondrian_inject.c)
        waits for the IOKit service MondrianGPU, then dlopen()s
      /usr/libexec/mondrian-gl.dylib                            (eagl.c + gl_osmesa.c)
        its constructor replaces seven -[EAGLContext ...] methods
      then patches two vtable entries of CA::OGL::GLESContext
```

Everything happens inside **backboardd**, where CoreAnimation's window server draws; no other
process is changed. One change outside `tools/gpu/`: `load_gpu_test()` must also dlopen the injector.

Two dylibs, because they fail differently: `mondrian-inject` needs only IOKit and the shared cache
and is the thing that can break a boot; `mondrian-gl` pulls in Mesa (`@rpath/libOSMesa.8.dylib`) and
loads only after the GPU service exists. If either refuses, backboardd keeps its renderer and the
port works as it does today (`mondrian-gl:` says so in the console).

CoreAnimation picks its renderer once per process: Metal, else OpenGL ES, else software. The kernel
publishes an empty `IOAcceleratorES` (`0114`) with no `MetalPluginName`, as the working a6xx port
does; whether our build then chooses GLES is the first thing to look for in the log. The GLES
renderer also needs a display mode and a surface: `IOMobileFramebuffer` (`0085`) publishes both and
shows whatever surface a swap names (by copying its layers into the panel's memory).

## The surface path

`eagl.c` receives an `IOSurfaceRef` in `-texImageIOSurface:...` (a surface to show) and
`-attachImage:toCoreSurface:invertedRender:` (a surface to draw into). It has two ways to use it:

- **No copy** (`surface_shared()`), the GPU path: `mondrian_gl_surface_texture(gl, IOSurfaceGetID)`
  -> `glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, id)` -> Mesa's `osmesa_st_get_egl_image` ->
  `osmesa_surface_resource` -> the Darwin libdrm shim -> **request `0x7e`** on `MondrianGPU`, which
  must answer with a GEM handle, an IOVA and the surface's size/offset/row-bytes. `0x7e` is not in
  the kernel yet (0x40-0x4c only, `0182`), so it returns an error and the copy path below runs.
- **Copy** (`surface_to_texture()` / `target_to_surface()`), which works against Mesa alone: the
  surface is uploaded with `glTexImage2D`/`glTexSubImage2D` and the frame is read back with
  `glReadPixels` at `glFlush`/`glFinish`. Correct pixels, two copies a frame; `glcopy=1` forces it.

`tools/gpu/gl_osmesa.c` documents the request and the three things the kernel has to do for it:
find the surface by ID, make a wired GPU buffer of it, map it into the CP's stage-1 context. Mesa's
half is missing too: the no-copy path's two hooks and the OSMesa ES profile `mondrian_gl_create()`
asks for (without it there is no context at all) are not in `tools/mesa/mondrian-darwin.patch`.
Both are dependencies to schedule, not userland problems.

## Files

| file | what it is |
| --- | --- |
| `gl_osmesa.c` | the four-function GL shim (`mondrian_gl_*`) over Mesa OSMesa, and the surface call |
| `eagl.c` | the window server's OpenGL ES: `EAGLContext` methods and the function table (from ios-topaz) |
| `mkeagl.py` | generates `eagl_gen.h` from `eagl_slots.txt` and the SDK's GL headers (never committed) |
| `eagl_slots.txt` | which table offset is which GL function; 30 entries known, the rest is found on the device |
| `mondrian_offsets.h` | every build-specific number: cache addresses, vtable slots, table offsets |
| `mondrian-offsets.py` | re-derives the CoreAnimation numbers from an extracted Mach-O |
| `mondrian_inject.c` | the constructor in backboardd: wait, load, hook, and the `glslots=1` dump |
| `build.sh` | builds and ad-hoc signs both dylibs |

Boot-args are read by `eagl.c` and `mondrian_inject.c` themselves: `glslots=1` (dump the table and
do nothing else), `gltrace=FIRST-LAST|_at=|_draws=|_function=N[,K]|_lit=1|_look=1|_place=...`,
`glframes=1`, `glshaders=1`, `glcensus=1`, `glplain=0`, `glblit=0`, `glcopy=1`, `glwait=0|1`,
`glsync=0`, `glfetch=0`, `glgroup=0`, `glprecision=0`, `glshow=TEXTURE`, `glslow=US`, `glenv=N=V`.

## Re-deriving `mondrian_offsets.h`

The values are this build's (iPhone X 16.7.16, 20H392) and only inputs to a check: the injector
patches a slot only while it holds the named function, and says so when it does not. Re-derive them
when the root changes or the log says "slot holds ..., expected ...".

1. `ipsw dyld extract <dyld_shared_cache_arm64*> /System/Library/PrivateFrameworks/QuartzCore.framework/QuartzCore -o /tmp/qc`
2. `tools/gpu/mondrian-offsets.py /tmp/qc/QuartzCore/QuartzCore -o tools/gpu/mondrian_offsets.h`
3. With `glslots=1` on the device: `mkeagl.py --from-log <log> --write-slots eagl_slots.txt`, rebuild.

Step 2 reads QuartzCore's symbol table, finds `__ZTV...GLESContextE` and the two
`GLContext::function_*` methods, and *measures* which vtable entry holds each (they move when the
class layout does), writing the vtable address, both slot offsets and both function addresses;
`ipsw dyld symaddr <cache> <address>` names one address by hand (what `tools/ios-crash.py` does for
crash PCs) when an image has no local symbols. Step 3 is the only reliable source for the function
table: iOS's GLES builds it at run time, so the dump is the definition. `mkeagl.py --check` lists
slot entries the headers cannot type.

One pair the tool does not derive: `MONDIAN_CA_CONTEXT_STATE` / `MONDIAN_CA_FUNCTION_FIELD`, where a
GLESContext keeps the function it is drawing with. They match the a6xx port. If the console shows
`CoreAnimation's GL renderer has no function N` with N >= 90, this pair is wrong for the build;
find it by disassembling the first instructions of `function_supported`.

## What is untested

- Every part of it: no dylib has been loaded on the phone and no Mesa context has been created
  there. `build.sh` compiles and signs; that is all that has run. Whether `IOAcceleratorES` (`0114`)
  is enough for CoreAnimation to choose GLES, and whether it then presents through `0085`, is open.
- The 30 table offsets in `eagl_slots.txt`: every other call CoreAnimation makes is "CALLED AND NOT
  THERE" until step 3 above fills the list in, so a first boot with it as it is draws nothing.
- Request `0x7e` is absent, so frames are copied: the cost of an 11 MB BGRA readback each way is
  unmeasured, and so is Mesa's a730 driver here (`docs/MONDIAN_GPU.md`).

## First pixels, in order

1. Boot the kernel as it is (`gpu=1 ... gpusubmit=1`) and confirm `MondrianGPU` exists
   (`tools/mondrian-gpu-test.c` prints `MONDRIAN GPU TEST: PASSED`).
2. Mesa (the mesa agent's `tools/mk-mesa-ios.sh`): `libOSMesa.8.dylib` at
   `/usr/lib/libOSMesa.8.dylib`, `FD_MESA_DEBUG=sysmem` in the environment until buffers are trusted.
3. `tools/gpu/build.sh OUT`, install `OUT/mondrian-gl.dylib` and `OUT/mondrian-inject.dylib` under
   `/usr/libexec/`, and point `load_gpu_test()` at the injector.
4. Boot with `glslots=1` added to the boot-args; the console gets `mondrian-gl: slot 0x.... gl....`.
   Complete `eagl_slots.txt` from it, rebuild, boot without `glslots=1`.
5. Read three log lines: `an OpenGL ES 3 context for CoreAnimation, by Mesa` (renderer chosen),
   `-attachImage: texture N is IOSurface M` (a frame goes into a surface), and `CALLED AND NOT
   THERE` (table entries still missing).
6. Expect the copy path to be slow. Then schedule request `0x7e` and the display's
   `MondrianWaitsForGPU` property (the frame is waited for in the dylib today, `glwait=1`), and
   compare against the 6.4 fps baseline.
