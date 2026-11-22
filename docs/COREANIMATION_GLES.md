# CoreAnimation on the GPU (OpenGL ES)

**Running on hardware and drawing through Mesa.**
In `backboardd` the injector loads, all seven `-[EAGLContext ...]` methods are replaced, both
`CA::OGL::GLESContext` hooks install, and a Mesa context is created. `GL_RENDERER` reads `FD725`,
so Mesa's freedreno backend rasterises on the Adreno; OSMesa is only the off-screen surface.
CoreAnimation's frames reach the GL path and are drawn in place into the display's IOSurface:
`1 drawn in place, 0 pictures copied out`, a steady frame in 9 ms. The GPU's buffer is not what
the panel scans, so OSMesa copies it into the CPU-side surface: that is the `copying out` cost on
the frames that show one (10-13 ms, `docs/UI_PERFORMANCE.md`). What is left is pacing and the
texture uploads that fail, both in `docs/MONDIAN_GPU.md`. The traps, in
the order they were paid for:

- **The ES profile of OSMesa faults on this driver.** `OSMesaCreateContextAttribs` with the ES
  profile (mapped to `API_OPENGLES2` by `tools/mesa/mondrian-darwin.patch`) creates a context
  whose first `OSMesaMakeCurrent` dies with SIGBUS in `_platform_memmove` inside
  `OSMesaMakeCurrent`, killing `backboardd`. The Mesa test draws with the compatibility profile,
  so that is what the window server uses now (`OSMesaCreateContextExt(GL_RGBA, 24, 8, 0)`), with
  the shaders rewritten to GLSL 120 (`#version 120`, no precision words, `gl_FragData` native).
- **A second OSMesa context kills the compositor.** `mondrian_gl_destroy()` is a no-op so the
  one context outlives every `EAGLContext`, but the sharing loop only looked at the live
  `contexts[]`: once CoreAnimation released its contexts (`_detectDisplays` does), the next
  `initWithAPI:` found nothing to share and created another OSMesa context. That one asks the
  GPU for its screen buffers, and when the allocation is refused (`MondrianGPU: gem_new 0x4000
  refused`) the fault is inside `OSMesaCreateContextAttribs`, at address 0x1c, and takes
  `backboardd` with it. The whole UI then freezes — no swaps, `backboardd pc=0x0` in the SMP
  sampler, SpringBoard waiting — which reads like "touch does not work". Reuse the file-scope
  `the_gl` whenever it exists.
- **The kernel writes the dylibs into `/private/var/vm`, not `/usr/libexec`.** The root is
  mounted `MNT_RDONLY` (`rootfs mount flags 0x400d001`, and `vnode_open` there answers EROFS);
  `/private/var` is a later mount and is writable (the pager makes its swap file in
  `/private/var/vm`). The write retries until that mount exists (12 s measured), and the injector
  prefers `/private/var/vm/mondrian-gl.dylib` over `/usr/libexec/mondrian-gl.dylib`, which only a
  flash can change. The kernel therefore carries `mondrian-gl.dylib` and
  `mondrian-inject.dylib` and writes them there at boot (`glblob=1`, `0220`,
  `tools/gen-glblob.py`), so a change to either is one `fastboot boot`. **Mesa is not carried**:
  `libOSMesa.8.dylib` (14 MB) only changes with `tools/wsl/push-root.sh --dylib … --mesa …`,
  which needs the phone in recovery and a fresh base dump.
- **`OSMesaMakeCurrent` overwrote the EAGLContext with the smoke test's red triangle.**
  The Mesa smoke test (`tools/mondrian-mesa-test.c`) freed its 256 KiB window but left its
  OSMesa context current on that memory. The next `calloc` — the 31408-byte `struct eagl` — was
  served the same block, and Mesa flushed the stale context's triangle over it when the window
  server made its own context current: `gl` read back `0xff0000ffff0000ff` (two red pixels),
  `sources[]` held the same, and `glLinkProgram` called through it (`pc 0xffff0000ff`). The test
  now detaches with `OSMesaMakeCurrent(NULL, …)` and destroys the context before freeing the
  window; the UI hook runs both smoke tests only with `gltest=1`. A second Mesa context in the
  process that renders the UI is what the `gltest=1` gate keeps out, and `context_gl()` still
  keeps the one context in a file-scope `the_gl` so a damaged field cannot decide whether GL
  works.
- **The function table is now the real one.** HackiOS publishes its
  `userland/src/eagl_slots.txt` for the same userland (409 entries) and all 30
  entries this port had agree with it exactly, so the rest was merged: 340 of
  them are exported by the Mesa build here and every other one becomes a
  "not there" stub. That is what turned `glCreateShader` from 0 into 1 and 2.
- **CoreAnimation does not always pass `table[0]`.** A call arrived with an argument that is not
  one of our contexts, so every field read as zero and `glCreateShader` went to Mesa's no-op
  dispatch (0, no GL error). `eagl_resolve()` matches the argument against the live contexts and
  falls back to the most recent one, saying so once.
- **A draw that reads the framebuffer read pixels of another tile.** A shader with
  `gl_LastFragData` (the shadows under the home screen's labels, a vibrant layer's colour matrix,
  the luma boost) reads what earlier draws in the same submission wrote — through UCHE, which
  does not see the colour cache. `FLUSH_PER_OVERLAP` orders those primitives among themselves but
  not against the draws before the mode was on, so the first triangle of each such quad took
  whatever the tile held: pieces of other icons, a vibrant box black, the wallpaper in bands.
  Flushing from the shim (`glflushdraws`, `glfbflush`) only moved the window for that
  framebuffer-fetch case and cost a submission per frame; its fix belongs in the driver, and
  `tools/mesa/mondrian-darwin.patch` has it: a
  `FD6_FLUSH_CCU_COLOR | FD6_INVALIDATE_CACHE` barrier before the first draw that reads the
  framebuffer after one that did not (`fd6_draw.cc`, `prev_draw_read_fb` in `freedreno_batch.h`).
  A different read — a draw sampling a texture written earlier in the same submission — is the
  shim's: `flush_draws = 2` (the default) submits before it, which fixed the Control Center's
  module backdrop (`docs/UI_PERFORMANCE.md`). `build-kernel.sh` embeds
  `out/gpu/mondrian-gl.dylib` as it finds it; it now rebuilds the library when
  `tools/gpu/eagl.c` is newer, because a boot that carried an older copy read as "the flush did
  nothing" (measured 2026-11-21).
- **The eight-times downsample that starts a backdrop's blur is not tinted by the layer that asked
  for it.** CoreAnimation's own four- and six-sample downsamples multiply the picture by nothing;
  the colour of the corners is the layer's opacity, which it applies where the layer is laid on
  the screen (`ds8`, `box_fragment`). Tinted, everything made of the backdrop — the blur, the
  luminance curve, the colour matrix — worked on a picture as dark as that layer (0.45 for a
  translucent badge) and a vibrant box over a bright wallpaper came out black.
- **Nobody draws the wallpaper.** The poster is a 1326x1326 one-byte surface that
  `CollectionsPoster` renders with Metal; this port has no Metal, so the surface keeps whatever
  the allocator left there. `gpusurfpat=1|2|3` (`MondrianGPU.cpp`) fills a freshly adopted
  surface with white, black or a ramp to prove it; the bands over the lock screen's wallpaper are
  that memory, not a mis-sampled texture. The UI therefore draws the still picture itself
  (`mondrian_wallpaper` in `tools/mondrian-ui-hook.m`): a gradient painted into the wallpaper's
  own window and, dimmed, under the App Library's cards, which is what the empty capture group
  was supposed to show. The library's backdrop and the wrong-label half of this are in
  `docs/UI_PERFORMANCE.md`.
- **The Control Center's module platters share a backdrop capture.** The sheet's
  own background (`...modulesBackground`) draws the blurred screen correctly;
  the module platters' shared capture (`ControlCenterModuleBackground.modules`)
  comes out as a sheared fragment of the pane when the sheet opens over
  Settings > Bluetooth, and is clean over the home screen. The capture trace and
  the levers already ruled out are in `docs/UI_PERFORMANCE.md`; it is not the
  poster.

The rest of this file is the design. CoreAnimation draws through Mesa into the display's IOSurface
with no copy; the no-copy path below is what does it.

## Reading the system frameworks

The frameworks this file talks about exist only inside the dyld shared cache; the
`*.framework` directories in the iOS root hold resources and no code. `ipsw dyld extract` is the
obvious tool and it does not work here: every `ipsw dyld` subcommand opens the cache's companion
`.symbols` file first, and this workstation's copy is truncated (28 bytes), as is the main cache
(12 MB). `tools/dsc-image.py CACHE_DIR SpringBoardHome` reads the subcaches instead -- they are
intact -- follows the mapping tables to each segment, drops the shared `__LINKEDIT` and writes a
thin arm64 Mach-O that `llvm-objdump` and REA's artifact reader both open:

    tools/dsc-image.py /root/dsccache SpringBoardHome /tmp/SpringBoardHome.arm64
    llvm-objdump --macho -p /tmp/SpringBoardHome.arm64

`dsc-image.py` takes an image by name, and this cache holds some names twice (two
`libc++abi.dylib`, one for DriverKit); for an address from a crash record use
`tools/dsc-va.py` instead, which pins the image by the address itself
(`docs/UI_PERFORMANCE.md` has the `--slide` rule).

The offset still needs a function name, which the cache image does not carry.
The companion `.symbols` file does: on this workstation it is a decmpfs type-14
resource fork (LZBITMAP, 64 KiB chunks), and `apfs-fuse`'s `DecompressLZBITMAP`
expands it to a second 592 MB dyld cache whose header at 0x4000 lists 8.7M
symbols. That decoder is GPL and stays outside the tree; `tools/dsc-sym.py`
reads the expanded file and prints the symbol with the largest value <= the
address:

    tools/dsc-sym.py /root/symbols.txt 0x1883c460c 0x1884088a0
    0x1883c460c -> __ZNK2CA6Render5Image16retain_iosurfaceEv +0x0
    0x1884088a0 -> __ZN2CA3OGL11GLESContext12retain_imageEPNS0_5ImageEPNS_6Render7TextureEb +0x10c

REA on Windows cannot analyse a Mach-O with its own providers: Hopper and the native utilities
are macOS, and Ghidra on this platform accepts only PE and 6502. The provider that does run here
is Rizin, through `execute_rizin_command`; it is installed at
`%LOCALAPPDATA%\rizin\rizin-win-installer-vs2019_static-64\bin\rizin.exe` and its path is in
the `rea` server entry of `~/.config/opencode/opencode.jsonc` as `REA_RIZIN_COMMAND` (the value is
read when the server starts, so a change needs a client restart). Rizin reads the rebuilt image as
`MACH064`/`arm`/`64`; REA's own artifact reader reports its format as `unknown`, which is harmless
for the commands. `ic` prints no Objective-C classes on a rebuilt image (observed), so the class
and method lists have to be read from the `__objc_classlist` / `__objc_const` sections directly.

What the image already answers: `WallpaperCaptureGroup` is the backdrop group the library's
materials name, and the library's background is built from `SBFFeatherBlurView`,
`SBDarkeningImageView` and `SBFolderBackgroundView` -- a blur of the wallpaper and a darkening on
top, which is why an empty capture is black rather than merely wrong.

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
port works as it does today (`mondrian-gl:` says so in the console). `tools/gpu/build.sh out/gpu`
builds both; `tools/install-userland.sh ROOT.img --gl out/gpu/mondrian-gl.dylib --inject
out/gpu/mondrian-inject.dylib` puts them in the image's `/usr/libexec`.

**The hook and Mesa are one build.** `mondrian_gl_surface_texture()` hands the IOSurface number to
`glEGLImageTargetTexture2DOES`, and Mesa's `osmesa_st_get_egl_image` resolves it through the
`mondrian-darwin.patch` hook. A root whose `libOSMesa.8.dylib` predates that patch still exports the
entry point, so the hook calls it and Mesa jumps through a NULL driver pointer: `backboardd` dies with
`pc 0x0` in `egl_image_target_texture` as soon as it attaches the display surface, and no frame is
ever presented (the console keeps painting, so it reads as "never reaches the UI"). Install
`out/mesa/stage/libOSMesa.8.dylib` (`tools/wsl/install-dylibs.sh --mesa out/mesa/stage`) with the
hook; the two md5s must match.

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
  answers with a GEM handle, an IOVA and the surface's size/offset/row-bytes. The kernel side is in
  `0182`; the Mesa hooks and the `glEGLImageTargetTexture2DOES` call are in this tree. They have
  not been built or run on the phone yet.
- **Copy** (`surface_to_texture()` / `target_to_surface()`), kept as a bisect knob only: the
  surface is uploaded with `glTexImage2D`/`glTexSubImage2D` and the frame is read back with
  `glReadPixels` at `glFlush`/`glFinish`. Correct pixels, 5.7 s a frame at 1440x3200;
  `glcopy=1` forces it. The upload has to take the *surface's* pixel size, not the format
  CoreAnimation asked the texture to have: the lock screen's poster is an L008 surface (one byte
  a pixel, 1536 a row) and uploading it as BGRA made `UNPACK_ROW_LENGTH` 384 pixels a row, four
  times the surface's, so the wallpaper read as white — the `255 255 255 255` the draw trace finds
  where the poster is drawn. One byte a pixel uploads as `GL_LUMINANCE`, two as
  `GL_LUMINANCE_ALPHA`, and GL converts them into the RGBA storage the texture already has.

**A client CGImage does not reach the render server.** Measured 2026-11-19: the layer is
given the picture's four coloured quadrants, CoreGraphics fills an IOSurface of the same size
correctly inside the app, and the window server creates a surface for that image, takes one write
lock and leaves it all zero; the app never looks the surface up or locks it. The symbols cache
(`tools/dsc-sym.py`) names the create path: `CA::Render::Image::retain_iosurface() const`
(`+0x14060c`) creates the surface and its lock/unlock only move the seed, while
`CA::OGL::GLESContext::retain_image` (`+0x184794`) uploads the image from a CPU pointer that
`CA::Render::Image::copy_cgimage()` (`+0x140bec`) only wraps in a bitmap context. That pointer is
zero, so the loss is the image data the render server received, before any surface is involved.
A layer whose `contents` is a filled IOSurface draws the picture, so `tools/mondrian-ui-hook.m`
bridges a CGImage to a surface (default; `mondrian-layercsurf-off` keeps the CGImage path for an
A/B). The bridge is not only for pictures: every element UIKit draws as an image travels that same
road, and the floor it used to have (300x200 pixels) cost the small ones. Measured 2026-11-20 on the
Settings list: the Airplane Mode row's switch drew its track (a plain colour layer, `bg 78788052`
`corner 15.5`) and no knob, and the knob is a `UIImageView` of 43x43 pt whose layer holds a 129x129
CGImage -- under the floor, so the CGImage kept the broken road and the ring shows
`MONDRIAN SURF: backboardd create ... 129x129 fmt 0x0 ... size 81920` right after the app built it.
The bridge now converts every CGImage of 4x4 or more, pads the surface row to 16 bytes so any width
works, and is built as a dylib of its own (`tools/mondrian-layer-bridge.m`) because the hook carries
the services' sixteen dyld interposers; `0402` injects that dylib into every exec whose path contains
`.app/` or `/WebKit.framework/`, so Settings carries the bridge and none of the hook
(`mondrian_ui_hook` in `tools/boards.py`). That is every app bundle the system can launch - the system
apps under `/Applications/`, an App Store app under
`/private/var/containers/Bundle/Application/<uuid>/Name.app/Name`, its extensions under
`.app/PlugIns/` - plus the WebKit services. Matching `/Applications/` alone reached the system apps
and nothing else: measured 2026-11-22, the bridge ran only in Preferences, SpringBoard and Spotlight,
so a third-party app and a web page still lost every picture. The app match has to use the whole path
(`cn_pnbuf`): by the time the environment is copied, `cn_nameptr` points at the
last component, so a `strncmp(name, "/Applications/")` never matches an app --
which is why the first 0402 boot injected nothing and said nothing.

Substituting the surface for the picture has a second edge: UIKit reads a layer's `contents`
back and expects the CGImage it put there. Measured 2026-11-21, opening Settings
asserted in `-[_UIImageCGImageContent _initWithCGImageSource:CGImage:scale:]`
(`_UIImageContent.m:533`, "imageRef passed is not a CGImageRef") and SpringBoard
aborted `sig 6`. The hook keeps the picture on the layer itself (an associated CFDictionary holding the image
and the surface ID it was made for), so no fixed table can evict the layer UIKit is about to
read; a copied layer that never went through `-setContents:` has no box, and for it the surface
is rebuilt into a CGImage over its own pixels (the port's IOSurface kernel ignores properties,
so the test is a 32-bit row). The app bridge answers `-contents` by caller: the picture for
UIKitCore, and the surface the layer holds for QuartzCore's commit, so CoreAnimation's
transaction carries the surface and no server-side copy is made. Measured 2026-11-21: the
Airplane Mode and Bluetooth toggles draw their knobs (`129x129`, `fmt 0x42475241`, `bpr 528`)
with no `backboardd create ... 129x129 fmt 0x0` after the app's surface. Answering `-contents`
with the surface for every caller, with the picture rebuilt at that UIKit initializer, froze
presentation with no commit and no crash (measured 2026-11-21); the picture-returning default
is the resting state.
The rebuild path itself must never wait on the server: a read lock on a surface the render server
holds (`IOSurfaceLock(..., kIOSurfaceLockReadOnly)`) is exactly the shape of that freeze, so
`mondrian_surface_picture` asks for `kIOSurfaceLockAvoidSync` and reads the mapping even when the
lock is refused, with a ring line the first four times. A local WebKit page loads -- the host's HTTP server logs its icon GETs --
and still draws black, so the same server-side surface path keeps both the picture and the page off
the glass; that one is not bridged because WebKit's pictures arrive as layer contents in the
network process, and it stays open.

`tools/gpu/gl_osmesa.c` documents the request and the three things the kernel does for it: find
the surface by ID, make a wired GPU buffer of it, map it into the CP's stage-1 context.
`osmesa_surface_resource` accepts both CoreAnimation's plain `'BGRA'` surface and the two-plane
`'b3a8'` display surface (plane 0 is the picture).

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

1. `ipsw dyld extract <dyld_shared_cache_arm64*> /System/Library/Frameworks/QuartzCore.framework/QuartzCore -o /tmp/qc`
   (a public framework, and this build's cache is `arm64`, not `arm64e`)
2. `tools/gpu/mondrian-offsets.py /tmp/qc/QuartzCore --dsc <cache> -o tools/gpu/mondrian_offsets.h`

   `--dsc` matters: the vtable lives in the cache's `__AUTH_CONST`, and an extracted image loses
   those pointers, so the slots come back empty without it. Measured on the 16.7.16 build this way:
   vtable `0x1d5b2f6e8`, `function_supported` at slot `0x378` (entry 111) and `function_uniform`
   at `0x388` (entry 113) — the values the header already carried.
3. With `glslots=1` on the device: `mkeagl.py --from-log <log> --write-slots eagl_slots.txt`, rebuild.

Step 2 reads QuartzCore's symbol table, finds `__ZTV...GLESContextE` and the two
`GLContext::function_*` methods, and *measures* which vtable entry holds each (they move when the
class layout does). Step 3 is the only source for the function table: iOS's GLES builds it at run
time, so the dump is the definition, and `mkeagl.py --check` lists entries the headers cannot type.

One pair the tool does not derive: `MONDIAN_CA_CONTEXT_STATE` / `MONDIAN_CA_FUNCTION_FIELD`, where a
GLESContext keeps the function it is drawing with. They match the a6xx port; `CoreAnimation's GL
renderer has no function N` with N >= 90 on the console means this pair is wrong for the build.

## What is untested

- The dylibs run on the phone (`MONDRIAN GL:`/`MONDRIAN DRM:` in the ring) and the no-copy
  surface path is measured: `1 drawn in place, 0 pictures copied out`, a 39 µs copy, 9 ms a frame.
  CoreAnimation already chooses GLES.
- The 30 table offsets in `eagl_slots.txt`: every other call CoreAnimation makes is "CALLED AND NOT
  THERE" until step 3 above fills the list in, so a first boot with it as it is draws nothing.
- Pacing. `frame_end()` waits for the frame because nothing else does: the display driver does not
  wait for the submission that named the surface, so a `glFinish()` per frame serialises the CPU
  behind the GPU and the display swaps at most 20 times a second (`glwait=` in `tools/gpu/eagl.c`;
  `docs/MONDIAN_GPU.md`). A fence the compositor can wait on at present time is not written yet.
- The texture uploads fail (`glDrawElements: 0x502`, `glTexImage2D: 0x505`), which is why the
  wallpaper and some text are white blocks.

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
6. Expect `0 copied out, 1 drawn in place` in the frame line, which is what the phone reports now;
   `1 copied out` means the no-copy path did not take and a frame costs 5.7 s (`glcopy=1` also
   forces it). The `MONDRIAN FB: fps` line only counts display swaps: with `glwait=1` the frame
   waits on the CPU and the swap count drops even though the GPU is faster.
