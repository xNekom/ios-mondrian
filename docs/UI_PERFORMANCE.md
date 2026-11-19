# UI performance

What makes the phone feel slow, measured from the console ring. The frame
budget is only one of three faults: a static screen draws no frames at all, and
the system spends about three of its seven cores on a launch/crash loop. Which
fault a slow moment belongs to decides what to fix.

Every number comes from a ring dump (`tools/usb-ring.py dump`); the lines are
already printed by the kernel and the injector, so a measurement costs one boot
and no rebuild.

## When the screen stops presenting

A boot that reaches SpringBoard and then stops drawing is not always a frame
budget problem: the compositor only presents when something changes, so `fps 0`
on a still screen is normal, and what matters is whether a touch brings a frame.
`tools/usb-ring.py fps` asks the screen dump for eight rows over USB and counts
the samples whose hash changed, so it cannot see more than 10 to 21 frames a
second -- and it cannot see a gesture at all: `swipe` runs `ud_cmd_touch` on the
gadget's command thread and that sleeps 8 ms per step, so the whole ~1.9 s
gesture blocks the same thread the rows are requested from. A sampler started
during a drag prints `no screen rows` or a low count because of that, not because
the UI was slow; measured 2026-11-18. For frames during motion read the driver's
own summary instead (`MONDRIAN FB: fps`, `present`, `panel n/60`, one every 3 s,
and they stay in the ring after the gesture).

- **Idle is the driver's, not the compositor's.** Measured on a boot left
  untouched: the ring carries `MONDRIAN UI: idle timer left armed
  (mondriankeepawake=0)`, then `MONDRIAN FB: panel blank after 30 s without a
  frame` (the seconds are `mondrianfb_blank`) with the DCS write that follows it
  (`MONDRIAN BL: dma len 0 size 4 ... done 1`), then on the first touch
  `MONDRIAN FB: panel wake (touch)` and `MONDRIAN FB: panel on (dcs)`. Those
  lines are the check: a missing blank means frames never stopped (or the blank
  is disabled -- it is, while the injector renders through Mesa: the DCS write
  resets the phone, `docs/MONDIAN_GPU.md`), `panel off refused` means the panel
  rejected `0x28` and the black-paint fallback ran, and a missing wake line means
  the touch never reached the driver. None of it costs a rebuild.
  `present 0/s` in the same dump is the still screen, not a fault: the samples
  that follow a touch read 4-5/s.
  Measured 2026-11-19 with `PREFIX_ARGS=mondrianfb_blank=30` (so 30 is the
  first occurrence and the board's 0 cannot win): a 60 s idle window still
  logged no `panel blank`, no `panel wake` and no `MONDRIAN BL` DCS line, and
  the lock screen read `present 0/s`. The timer is gated on
  `fLastPresentTicks != 0`, so a boot whose screen never had a CA present cannot
  arm it; print that gate before changing the timer. The default remains 0.

- **An app launch that times out freezes the compositor.** Measured chain, all
  in the ring: SpringBoard's launch thread waits on an `os_unfair_lock` inside
  `-[FBProcess bootstrapLock:]`, entered from
  `FBProcessManager _bootstrap_consumeLock_addProcess:synchronously:`; the
  thread that holds it is in `-[FBProcess _bootstrapAndExec]` waiting for the
  XPC reply to `-[RBSConnection executeLaunchRequest:...]`; runningboardd is in
  `AppServerSupport`, waiting for launchd. Nothing reaches `posix_spawn`, so no
  `exec` of the app appears and no `MONDRIAN EXECFAIL` either. The lock stays
  held, and the UI stays in the launch transition: `fps 0` from then on. The
  launch probe therefore only runs with `mondrianprobe=1`; a boot without it is
  a boot whose screen keeps working.
- **A black screen with only console text is a black frame, not a missing
  frame.** The copy of the layer into the panel runs (`mode copy`, `panel n/60`
  follows the content), so the glass shows whatever the layer holds. When the
  GLES path stops submitting, that layer is black and the only text left is what
  the kernel HUD wrote. Measured on one such boot: 2 323
  `MESA: error: msm_dump_submit` plus 56 `flush_submit_list:135: submit
  failed: -5`, while the driver reported `uc retired 0 of 2000`: the ring stopped
  retiring, so every later frame is empty. `mondrian-gl: rate` falls to 0.0 a
  second and `fps` follows it. This is a GPU problem, not a compositor one. The
  `-5` is the driver's own gate timing out: `uc fence gate seq 2001 waits for
  1953 … rptr 0x4669 wptr 0x4669 int 0x0`, and `0322`'s fence-page dump shows
  every slot reading 0 while the CP had consumed the ring, so the fence the gate
  waits for never appears where the driver looks and the ring stays full.
- **The fence path itself works, and this is the ladder that rules things out.**
  At bring-up the same page takes both writes: `cp memwrite … canary 0x600dc0de
  fence 0x600dc0df` into memptr `+0x800` / `+0x810`, and `cp ib … canary
  0x1b00dead fence 0x1b00deae`. The page's first word is the CP's own read
  pointer and it keeps tracking the write pointer (`uc prog seq 1984 … sh
  0x3e10` with `rptr 0x3e10 wptr 0x3e10`), so the CP still writes into that page
  late in the boot. `cpfence=mem` was booted and changes nothing (same stuck
  sequence, same zeros), so the fence opcode is not the difference either: the CP
  parks at the end of one specific submission, before the fence packet, with
  `int 0x0` and no `CP_HW_FAULT`. `cpevent=4` (CACHE_FLUSH_TS, the event mainline
  and Mesa use) was booted as well and is identical. `0323` prints the ring dwords
  behind the cursor and they name it: `70460004 08000031 00300834 00000000
  000007d0` is `CP_EVENT_WRITE`, CACHE_CLEAN, to page `+0x800` + slot 13 (the
  fence of sequence 1997) with value 2000, sitting in the ring unexecuted. So the
  packet is present, its destination is right and the same dword took the
  bring-up canary. The driver's `0323`/`0324` ring dumps and
  `tools/decode-pm4.py` name what it is: every one of those submissions is
  `CP_INDIRECT_BUFFER_PFE` to iova `0x400000`, size 9, then its fence — that is
  `mondrian_cp_ib`, the driver's own buffer, so the ring was full of the
  **bring-up stress loop** (2 000 back-to-back submissions) and not of Mesa.
  When one of them stops being answered the driver marks the GPU as stopped
  (`gpu stopped answering, submissions refused`) and every later Mesa submit
  returns `-5`, which is the black layer.
- **`cpstress=0` is the default for a usable boot.** With the stress loop skipped
  the same boot has *zero* `flush_submit_list` errors, the fence gate never
  fires, and `fps` ramps to 60 with the home screen on the glass. The loop is a
  bring-up diagnostic (it proves ordering across two ring laps); it must not run
  in an image that is meant to be used, so `0344` leaves it off unless
  `cpstress=1` is passed.
- **`/private/var/vm` keeps the previous boot's hook.** `kern_exec` injects the
  copy in `/private/var/vm` when it exists, and launchd and xpcproxy exec before
  the kernel rewrites it, so they load the previous build. A hook change reaches
  them one boot later; a build with no guard for launchd takes the boot down to
  two processes.
- **`usb-ring.py screen` reads the panel itself.** Half scale, RGB565, one row
  per request, straight out of the memory the panel scans out: what the capture
  shows is what is on the glass, kernel console text included. That is how the
  console-over-UI text below was measured -- and why a capture can show the
  console where the glass has the UI: both write the same memory.

## The frame budget

`MONDRIAN FB: fps` prints once a second and `mondrian-gl: frame` every 20th
frame (and the first 40), both steered by boot args (`mondrianfb_fps=1`,
`glframes=1`). `gpustat` adds `gpuacct` (submissions, fence waits and their
time, doorbell to fence against the wall clock) and `gpuperf` moves the GPU's
perf index at run time.

Measured 2026-11-17 with the same eight page swipes (~20 s of motion) in one
boot each, so the three columns differ only in what changed:

| | 285 MHz | 900 MHz | 900 MHz + AMP |
| --- | --- | --- | --- |
| frames at the panel (`intf` `fc`) | 60/s | 60/s | 60/s |
| frames the compositor produced | 41-47/s | 48-52/s | 52-57/s |
| `mondrian-gl` frame total | 17.1 ms | 17.1 ms | **9.2 ms** |
| of which waiting for the GPU | 13.3 ms | 8.5-10.5 ms | **4.5 ms** |
| CPU inside the GL calls | 7.9 ms | 7.9 ms | **3.85 ms** |
| kernel copy into the panel | 4.2 ms | 3.5 ms | **2.4 ms** |
| of which the cache clean | 1.2 ms | 1.2 ms | **0.49 ms** |
| frames ending on a P core | 32 % | 32 % | **99.8 %** |

- **The panel is not what drops frames.** The interface sends one frame every
  tick (`intf fc` +59..+61 a second) throughout; the compositor produces
  52-57. The frames that are missing are the ones whose work crosses the
  period: `late` averages 7.5 ms and peaks at 11-12, the copy peaks at 3.3-5.4,
  and that sum is where a 33 ms cadence comes from.
- **The GPU was at its idle OPP** (index 2, 285 MHz) for the whole session
  because the HFI vote is sent once at GMU start and kgsl on Android re-sends
  it per submission. `gpuperf 13` at run time gives the top OPP and, by
  itself, 3.2x less GPU time per submission and +15 % frames; `0349` sends
  that vote from the first submission of the session, so nothing has to be
  asked for after a boot (`MONDRIAN GPU: active vote 13 (900 MHz) acked`).
  With the vote automatic and no ring command, the same swipe gives 55-58 fps.
  Index 13 in the *boot* vote does not come back to fastboot; the run-time vote
  does (`docs/MONDIAN_GPU.md`).
- **The scheduler treated all seven cores as equal**: `NO_ECORE`,
  `MAX_CPU_CLUSTERS 1` and `cluster-type` 0 in every ADT CPU node left
  `__ARM_AMP__` undefined, one `PSET_SMP`, and 68 % of frames finishing on an
  A510. `0347` declares the A510 cluster `CLUSTER_TYPE_E` and the A710/X2 one
  `CLUSTER_TYPE_P`, which halves the CPU cost of a frame and moves almost all
  of it to the P cores. This is the single largest win measured so far and it
  costs nothing at run time.
- **The copy is not what drops frames, measured, and the panel is a single
  full-canvas layer.** `mondrianfb_nocopy=5` skips the copy five seconds out of
  ten, and the same swipe in one boot gives 54-56 fps in the `copy` seconds
  against 41-59 in the `nocopy` ones -- no gain, more variance, and a worse
  `late`, because a panel that never changes breaks the pacing the UI keeps
  against it. `swap` records show why the copy can be 1:1: one layer,
  1440x3200, `bpr 5760` (exactly `width * 4`), and CoreAnimation alternating
  two canvas surfaces (`s2`/`s3`), so the canvas is already double-buffered and
  a full-frame copy at present reads a complete image. A sliced copy (the caller
  plus kernel threads) was written and does not boot -- the first frame it
  serves ends the boot -- so it is not in the tree.
- **Nothing waited for the submission that named the surface.** The GL
  interposer skips its `glFinish` (a full sync drops the display to about twenty
  swaps a second) and the driver never looked at the fence, so `swap()` could
  copy a canvas the GPU was still drawing. `mondrianfb_gpuwait=1` (`0350`)
  waits, bounded at 100 ms, on the fence the submission path already handed out;
  measured on the lock screen it costs `gpuwait avg 155-447 us` a frame -- the
  GPU had retired the frame in most of them -- and the swap rate is 59-61 with
  `late max` 4.0-4.4 ms. It is off by default: what it buys is ordering, not
  frames.
- **Corruption in the image is one layer's content, not the path to the glass.**
  Measured 2026-11-17 on the App Library, finger held still on the glass: the
  blurred backdrop is drawn sheared -- a sawtooth of black blocks and a blue
  gradient cut on a diagonal -- while the status-bar clock, the cards
  (`Suggestions`, `Utilities`) and the dock icons in the same frame are crisp.
  The ring at that moment reads `fps 0`, `touch 355/s`, `0 textures refilled
  from IOSurfaces`, `0 pictures copied out` and no GL error, and the frames
  before it carry the usual 629-676 calls and 109 draws. The corruption
  survives new frames (the clock advances 1:06 -> 1:07 with the backdrop still
  sheared) and it survives the finger being held, so it is redrawn, not
  retained.
  A pitch or stride error in the copy would shear the clock and the dock too and
  they are correct, so the canvas, the double buffer and the panel are not where
  it starts. The backdrop layer is a **blurred snapshot of the panel**, so
  anything painted on the panel while the snapshot is taken ends up in it,
  blurred and enlarged: see the console bullet below.
  The backdrop layers are also the only ones at the wrong resolution, measured
  with the walker below: `UIScreen` reports scale 3.000 (native 1440x3200) while
  `SBHomeScreenBackdropView` and `SBSearchBackdropView` sit at
  `contentsScale 1.00` with layer bounds 480x1066.7. **That is not the cause**:
  forcing them, and the nested `CABackdropLayer`'s own `scale`, to 3.00 at run
  time left the artifact exactly as it was, and the layer classes, frames and
  transforms are all as expected. Do not spend another boot on the scale.
  `mondriangeom=1` runs the walker (`mondrian_effect_walk`): every visible
  window, each effect/backdrop view with frame, bounds, layer bounds,
  contentsScale, rasterizationScale and whether its transform is identity.
- **The kernel console was painting the log over a live UI; `0351` stops it.**
  Measured 2026-11-17: the bootstrap
  console (`osfmk/arm64/mondrian_early.c`) paints the tail of the log on the
  panel by default, and the ring counted **3.4 million characters painted in one
  session** -- about six 1440x32 lines a second -- on a boot whose UI was up.
  Two things make that visible rather than harmless: the console draws text
  *by position* over whatever the compositor put there, and `mondrian_early_scroll()`
  copies the frame buffer's own pixels up half a screen and fills the rows it
  frees with black. The compositor only repaints what changed, so the text, the
  shifted content and the black rows stay in the panel; the App Library's
  backdrop is a blurred snapshot of that panel (its clock, cards and dock are
  drawn crisp afterwards, so only the backdrop shows the damage). A panic
  that painted before the UI existed leaves `early_panicking` set, and from then
  on every line and every status row paints over the UI for the rest of the boot.
  `0351` gives the panel to the compositor at its first swap (the ring is fed
  before any quiet flag, so nothing is lost), stops a *recovered* copyin
  fault from painting six `KABORT` rows, and makes the status rows (`st …`,
  `SC …`, the console rate -- one of them a filled black band) follow the
  console off the panel; `mondrianfb_noconsole=0` restores all of it for a
  bring-up boot, and a panic still paints either way. Measured after it: the
  lock screen of a fresh boot has no console text and no bands at all, where the
  boot before it had six `KABORT` rows and two black bands.
  `0352` closes the other half, the fault the machine **survives** with no
  copyio recovery entry: `handle_kernel_abort()` printed its six rows and called
  `mondrian_early_panic_begin()` before it knew anything, and the `arm_fast_fault()`
  / `vm_fault()` below can still fix such a fault, after which the thread returns
  and the boot carries on with the panel taken -- measured 2026-11-18 as
  `KABORT esr 0x96000047 far 0xfffffe1f15edc000` on the glass of a boot that kept
  running, the lock screen answering no touch until a retry.
  `mondrian_early_panic_begin()` has no other caller, so that survived fault was
  the only case it served, and it is the one case that must not paint.
  Those numbers now go to the ring, `MONDRIAN KABORT: recovered|unrecovered
  esr … far … pc … lr … cpsr … x0 …`, and a fault that really panics still paints:
  `mondrian_early_fault()` writes its three rows with `hud_row_text()` directly,
  past `panel_text_allowed()`. Note for the next reader: `mondrian_early_reg()`
  writes with `putc` alone, so the old `KABORT` rows never reached the ring and no
  saved ring holds one -- a boot that shows them on the glass leaves no record
  after a reboot. Where the observed one comes from: its `lr`
  (`0xfffffe0007584a68`) resolves to `_mapping_free_prime_internal`, in the pmap
  pv-free path this board is documented to die in when the panel alias is torn
  out -- so the panel was being taken by a pmap fault, not by the UI.
  The fault has not reproduced since: three boots of the 0352 build and a
  `respring` (18 SpringBoard crash records, a lot of mappings freed and rebuilt)
  left zero `MONDRIAN KABORT` lines, so what is verified is the mechanism -- the
  only caller of `mondrian_early_panic_begin()` is gone -- not a boot that
  exercised it.
- **The `CRASH SpringBoard` records were this hook's own out-of-bounds read.**
  A record names `mh`, the **main executable**, and that binary
  (`CoreServices/SpringBoard.app/SpringBoard`) is only `0x98000` bytes: the hook
  is loaded right behind it, so `pc - mh = 0xa4b54` is not an offset in
  SpringBoard, it is `hook + 0xcb54`. Two things make that arithmetic safe
  instead of a guess: the hook prints its own base and size at load
  (`MONDRIAN UI: image0 <base> size <size> <path>`, added 2026-11-18), and the
  same dylib's `llvm-nm` names the function at that offset. Both records of one
  boot give the same `pc - mh`, and in the boot they came from the hook sat at
  `mh + 0x98000`: the site is `ldrb w12, [x11, #0x2]` in
  `mondrian_wall_inspect()`, the probe that prints `MONDRIAN WALL: pixel`.
  `places[]` there is written in full-panel coordinates (720x300, 720x1600,
  720x2900, 200x1600) and the probe runs on whatever image the wallpaper view
  holds -- measured once as **192x192**, where three of the four samples read up
  to 0.9 MB past the buffer, so the load lands in whatever is mapped after the
  allocation, which is the hole the record's `map before`/`map after` lines
  bracket. That is the intermittency: the same read crashes when the next page is
  not mapped and is silently accepted when it is. The `far`'s low bits are the
  arithmetic (`y * row + x * 4 + 2`), so treating them as an ivar offset was
  reading tea leaves.
  The fix skips a place outside the image and says so (`MONDRIAN WALL: pixel
  720,1600 outside 192x192`). The counts corroborate but do not prove it, because
  the read only crashed when the page after the buffer was unmapped: boots of the
  kernel before the fix left 0, 6, 12 or 18 records, and one of them left 0. What
  proves it is the skip: the three samples that were out of bounds on a 192x192
  image are now logged and not read, so the load cannot happen at all. And match
  the image by the record's own base, never by name: `dsc-image.py` takes the
  first cache image whose name matches, and SpringBoard.app, SpringBoard.framework
  and SpringBoardHome all do.
- **Which addresses a record carries, and which of them name anything.**
  `mondrian_crash_log()` prints run-time addresses plus `slide 0x…` and `mh 0x…`
  (its own comment: `unslid = pc - slide`), so a cache address is named by
  subtracting the slide and looking the result up; `pc - mh` is only useful for
  the main executable's own code. For a `SIGABRT` the `pc` names the abort, not
  the bug: read it as bytes and it is the return address after
  `mov x16, #328; svc #0x80; b.lo`, and 328 in `bsd/kern/syscalls.master` is
  `__pthread_kill` -- the thread sent itself `SIGABRT`, so the instruction after
  the syscall is where the signal was raised. Two processes aborting in the same
  library with the same `far` (`PhotosFileProvider` and `fileproviderd`, both
  `sig 6 code 0x0`) are running one shared assert, not corrupting one variable;
  the registers say which call, the ring's `exec`/`exit` lines say what the code
  was trying to start. `tools/dsc-va.py CACHE --slide 0x… ADDR…` does the whole
  lookup -- it finds the header by scanning back from the address, because the
  split cache has no single image table -- and `--disasm N` prints the code
  around it. Measured that way, the pair's backtrace is
  `__pthread_kill <- pthread_kill <- abort <- libc++abi ×5 <- CoreFoundation <-
  PlugInKit`, and `assetsd` plus the three speech plug-in hosts
  (`SiriTTSSynthesizer`, `KonaSynthesizer`, `MacinTalkAUSP`) share the same six
  frames before they diverge: four services running one libc++abi terminate
  path, which means an exception nobody caught, not a memory fault. Do not read
  the frames below `terminate` as a call chain -- measured, they land on function
  prologues, `bl` stubs and an address in DriverKit's half of the cache, because
  the frame-pointer walk has lost the stack by then. Naming the exception itself
  needs code inside the process, and `mondrian_ui_hook` injects the hook into
  backboardd and SpringBoard only (`mondrian_ui_hook=6`), so no probe of ours
  sees these services without widening that mask -- which puts our code inside
  the very process being measured.
- **The exception behind the abort family, named.** Measured 2026-11-18 with a
  probe injected into the services (`mondrian_ui_probe=1`, `0353`): fileproviderd
  raises

  ```
  NSInvalidArgumentException: *** -[NSFileManager createDirectoryAtURL:
  withIntermediateDirectories:attributes:error:]: URL is nil
  ```

  and nobody catches it, so it reaches `std::terminate` (the type the C++
  handler reads is `NSException`) and aborts. That is the shape of the family in
  one sentence -- a path that resolved to nil, treated as fatal -- and it is
  measured for this process, not for all five: assetsd never constructs an
  `NSException` under the same probe (see below). The probe also rules out two
  guesses: `com.apple.pluginkit.pkd` answers `bootstrap_look_up` with 0 (the
  broker is registered) and `containermanagerd` has its own log in the root
  showing it starts and finishes its first-boot cleanup, so neither is missing
  from the root.

  How it was read, because the loop is cheap and worth reusing: the hook only
  needs one `wfile` of `out/gpu/mondrian-ui-hook.dylib` to
  `/private/var/vm/mondrian-ui-hook.dylib` plus a `respring`; the services take
  the new copy at their next exec, so an iteration costs a build and about two
  minutes, not a kernel build and a boot. `glblob=1` rewrites that copy from the
  kernel's blob at mount, so after a reboot the delivered dylib must be sent
  again (or the kernel rebuilt) before the probe is armed. The injection itself
  is armed by a file too -- `/private/var/vm/mondrian-probe` holding something
  other than `0`, the same existence check the kernel already does for the dylib
  -- so instrumenting a service no longer needs the boot argument
  `mondrian_ui_probe=1` and therefore no longer needs a boot at all: measure, then
  write that file, and the next exec of a target is instrumented.

  What worked was hooking the exception
  at construction -- `+[NSException exceptionWithName:reason:userInfo:]` and
  `-[NSException initWithName:reason:userInfo:]` -- because CoreFoundation
  builds and throws it itself, so `-[NSException raise]`, the objc uncaught
  handler and `std::terminate`'s previous handler all miss it.

  Two traps in that probe, both measured: a hook that recurses changes how the
  process dies (the XPC interposer below did exactly that, so a `sig 11` in the
  guard page is evidence about the hook first and the process second), and calling
  the handler that `std::set_terminate` returns branches to a pointer that is not
  callable here (`pc 0xffffffffa7f9aa80`). The reason string is still valid
  because the exception is raised, and printed, before either of those.
- **A mobile-uid process resolves every container the appex needs, so the nil
  URL is not a missing container service.** Measured 2026-11-18 from SpringBoard
  (uid 501, the appex's own uid) with the URL probe (`/private/var/vm/mondrian-urltest`
  holding something other than `0`, then a respring): `group.com.apple.
  mobileslideshow.PhotosFileProvider` ->
  `/private/var/mobile/Containers/Shared/AppGroup/61F74B4E-…`, `group.com.apple.
  tipsnext` -> its own AppGroup, `NSHomeDirectory()` -> `/var/mobile`, and
  `URLsForDirectory:inDomains:` answers for Documents, Library, Caches and
  Application Support. That refutes the earlier guess that the nil URL is the
  group container waiting for `containermanagerd`: the service is still never
  exec'd (0 of 2870 `exec` lines, `bootstrap_look_up` answers 0, and this root
  has no `launchctl` at all -- `posix_spawn("/bin/launchctl")` returns `ENOENT`
  -- so asking launchd about a job means its private job API), and the lookups
  work without it. Nor is it on the path that opens Photos: tapping Photos
  starts no `fileproviderd` and no `photolibraryd`, only `assetsd`, which dies
  30 times in the same boot. Absence in an image proves nothing either: the root
  ships 129 app data containers and `com.apple.Preferences` is not one of them,
  yet Settings draws, so a container appears the first time an app asks for
  one.
- **`-URLForDirectory:inDomains:appropriateForURL:create:error:` is not on this
  Foundation, and calling it anyway aborts the caller.** `respondsToSelector:`
  says 0 and `class_getInstanceMethod` agrees, yet a probe that called it
  directly killed SpringBoard 20 times in a row (`sig 6`, the same
  `__pthread_kill <- abort` trace as the services). That is what made the panel
  go black between taps and read as "Photos draws nothing": the process drawing
  it had died. Use `URLsForDirectory:inDomains:`, which is there, and ask
  `respondsToSelector:` before every call into Foundation.
- **assetsd's guard-page death was the hook's own XPC interposer, and the
  exception was never in the way.** The dylib interposes
  `xpc_connection_create_mach_service` and asked `dlsym(RTLD_NEXT)` for the
  original, which resolves to the *replacement*: the first call recursed into
  itself, 0x140 of stack per level, until the guard page (`far = sp + 0x100`,
  `prot 0/7`, `bt` repeating one return address). `pc - mh` puts the fault at
  the interposer's second instruction, and the same trap was already paid for in
  `sandbox_container_path_for_pid` -- a `dlsym` on an interposed symbol cannot
  reach the definition. Taking the original from the `__interpose` tuple's
  second field fixes it, and with the fix assetsd dies `sig 6` again, which is
  the real abort. Reading pc against each process's own image table is what
  named it: the table is printed at exec by `/private/var/vm/mondrian-images`,
  `_dyld_get_image_header` already returns the slid address (adding
  `_dyld_get_image_vmaddr_slide` doubles the slide and reads nothing), and only
  `__TEXT` gives a usable range (a shared-cache segment at vmaddr 0 turns a
  segment union into a base in the middle of nowhere).
- **The exception is `NSInternalInconsistencyException`, and its reason names
  the wall: `assetsd requires TCCPhotosService access`.** It is read at throw
  time, not in the uncaught handler: the handler runs with 0x100 bytes of stack
  above the guard page, `-reason` faults there, and the report collapses to
  `reason ns 2 code 0xb: (none)`. Interposing `objc_exception_throw` (switch
  `/private/var/vm/mondrian-throw`) prints class, name, reason and a
  frame-pointer trace while the stack is intact, and that trace is the same one
  the image's 25 `assetsd-*.ips` reports carry:

  ```
  MONDRIAN THROW[555]: NSInternalInconsistencyException
     reason assetsd requires TCCPhotosService access
     #0 assetsd+0x162f0   #1 PhotoLibraryServicesCore+0x85250
     #2 PhotoLibraryServicesCore+0x85910   #3 Foundation+0x9de58
  ```

  So those reports are this build's, not an older one, and the failure predates
  the filesystem work.
- **The reason is decided by entitlements the port never attaches.** On a real
  device `assetsd` carries `com.apple.private.tcc.allow = [kTCCServicePhotos]`
  and TCC never prompts it; the image's own signature agrees (SuperBlob slot 5,
  5635 bytes of XML, `magic 0xfade7171`, with the same key). But
  `csops(CS_OPS_ENTITLEMENTS_BLOB)` answers `0` -- "no entitlements object" --
  in *every* process with the hook, SpringBoard included, and a `0` here is not
  an error: `proc_csops` returns it without setting one when
  `csblob_os_entitlements_get()` is NULL. `mondrian_amfi_vnode_check_signature`
  (`xnu 0030`) attaches them only when `cs_blob != cs_blob->csb_ro_addr`, and
  prints nothing when it skips, so the loop from blob to process is where the
  next measurement goes. That is also why nothing caught this earlier: the
  sandbox stand-in (`xnu 0043`) grants every privilege without asking, so only
  a userland consumer of entitlements -- TCC -- could notice. `mondrian-tccok`
  does not help, and neither `TCCAccessPreflight` nor
  `TCCAccessCheckAuditToken` is ever called by assetsd: it links
  `TCC.framework` but imports no `TCCAccess*` symbol.
- **Measured 2026-11-19: the blob reaches the process.** `0367` prints the blob
  `CS_OPS_ENTITLEMENTS_BLOB` looked at, and with `/private/var/vm/mondrian-images`
  armed, `assetsd` answers `5643 bytes magic 0xfade7171 tcc.allow yes photos
  yes`; `SecTask` gives the same `kTCCServicePhotos` and TCC preflight answers 1.
  The old `0` was the blob lookup, not the signature. `assetsd` still aborts
  `sig 6`, now in an uncaught C++ exception (the trace ends in `libc++abi`
  `terminate`); a boot without `mondrian-probe` shows the same crash at the same
  pc, so the hook is not the cause.
- **A hook change is only in the kernel when the kernel build rebuilds it.**
  `tools/wsl/build-kernel.sh` embeds `out/gpu/mondrian-ui-hook.dylib` when the
  file exists and never rebuilt it from `tools/mondrian-ui-hook.m`, so a kernel
  built after a hook edit carried the previous copy: on 2026-11-18 a probe added
  to the hook was absent from a fresh boot and read as a probe that never fires.
  The build now rebuilds the hook when the source is newer. The `/private/var/vm`
  copy is written by `glblob=1` at boot and answers `-> 30` (`EROFS`) while the
  root is still read-only, then retries; until that write lands, execs load
  whatever the file held from the previous boot, so compare sizes before
  believing a new hook is running.
- **The appex's death now has a message, and it is not the nil URL.** Measured
  2026-11-18 with the probe in mode 3 (`mondrian-exc` holding `3`: exception
  handlers, no URL resolvers), on the first `exec PhotosFileProvider` of a boot:

  ```
  MONDRIAN EXC[289]: init name   NSInternalInconsistencyException
  MONDRIAN EXC[289]: init reason plugin has invalid sandbox or container:
                                 error 2 path ?
  MONDRIAN EXC[289]: terminate NSException
  ```

  `error 2` is `ENOENT` and the path is literally unknown, so the appex is being
  told it has no container to be sandboxed with. That is a different failure from
  the `createDirectoryAtURL: URL is nil` fileproviderd raised: this one happens
  before the appex runs any of its own code. Seeding a container by hand for
  `com.apple.mobileslideshow` (directory tree plus the metadata plist an existing
  container carries, written by SpringBoard as uid 501) does not change the
  message, so libcontainer needs more than a directory with metadata to answer.
  Nor does the container manager add one: with it running, the directory holds
  130 containers, 3 of them photo-flavoured, and the only
  `com.apple.mobileslideshow` is the seeded `8F2B1C64-...`, so the daemon is not
  creating one for Photos either.
- **launchd was skipping the container manager because of its job plist.**
  Replacing `/System/Library/LaunchDaemons/com.apple.containermanagerd.plist`
  with `tools/launchd/com.apple.containermanagerd.plist` -- the same program and
  Mach services, without the `#IfFeatureFlagEnabled`/`#Then`/`#Else` dicts inside
  `ProgramArguments` and without the `_PanicOnCrash` dictionary -- makes launchd
  start it: `exec containermanagerd` appears in the next boot, the first time on
  this port. The appex still raises `plugin has invalid sandbox or container`
  with the daemon running and `KeepAlive` keeping it up, so that message is not
  waiting on the daemon either. Install the job with `wfile` and reboot; launchd
  reads that directory only at boot.
- **With the container manager running, `assetsd` starts -- and its uncaught
  exception is what blocks Photos.** Measured 2026-11-18 on the same root: before
  the job above was installed no `exec assetsd` appears in a boot at all; after it,
  `assetsd` execs and dies within seconds, 18 times in half a minute, each one
  `status 0xb` (SIGSEGV) with no `NSException` constructed, so the photo library
  is never there when Photos asks. The image itself carries **25 identical
  `assetsd-*.ips` reports** (2026-10-27/28; the HFS reader in `tools/hfs-audit.py`
  copies them out of the image):
  `EXC_CRASH`/`SIGABRT` after `std::terminate`, with `lastExceptionBacktrace`
  `objc_exception_throw` <- `assetsd+0x162f0` <-
  `-[PLLibraryServicesOperation _runOperationBlock:]` <- `-[NSBlockOperation main]`
  <- dispatch. So an Objective-C exception is thrown from inside a library
  services operation and nothing on that path catches it: this is the blocker for
  Photos, it predates the filesystem work, and it is not the sandbox query the
  appex raises. Today's throw-time trace reproduces that backtrace exactly
  (`assetsd+0x162f0`, `PhotoLibraryServicesCore+0x85250`), so the offsets do
  name this build's line; the reason is read at throw time, not from the
  reports.
- **A black capture with only a battery icon is the panel off.** Measured
  2026-11-18: `usb-ring.py key 116` is the power button, so using it to "wake"
  the phone turns the display off, and the next `screen` comes back black with
  the battery and the home indicator -- which reads exactly like an app drawing
  black. Wake with a tap or a swipe, and check the capture for the time in the
  status bar before concluding anything about what an app draws. Photos' own
  blank state is white with the status bar, not black.
- **A tap opens the appex, but only the launch that starts the app.** Measured
  2026-11-18: with Photos not running, tapping the icon starts `MobileSlideShow`
  and then `exec PhotosFileProvider` right after the touch (pids 494, 368, 319),
  which dies in the PlugInKit check below. Once it has died, tapping the icon
  again only brings the app's blank window back; the extension is not requested
  a second time. A `respring` did not restore the request in one measured pass
  (the app then opened with no new `exec`), so a fresh app launch is the trigger
  and a boot is the reliable way to get one.
- **The appex does have a container; the query for it is what fails.** Measured
  2026-11-18 inside the appex: its bundle identifier is
  `com.apple.mobileslideshow.PhotosFileProvider`, `HOME` and `NSHomeDirectory()`
  are `/var/mobile/Containers/Data/PluginKitPlugin/9702DC55-...`, and that tree
  exists with 414 entries (a plug-in gets a container under `PluginKitPlugin`,
  not under `Application`, which is why seeding an app container changed
  nothing). `sandbox_container_path_for_pid(getpid(), ...)` returns `-1` with an
  empty buffer, and `0043` explains it: the sandbox stand-in answers **ENOENT**
  to operation 4 (container path), 5 and 6 (extension issue/consume) and 0x43.
  `launchd op 4` appears in the ring too, so this is not specific to the appex.
  Error 2 is the exception's own number, so the message is that query failing.
- **Request 4 now answers, and a plug-in takes the path.** Measured 2026-11-18
  with `0354`: the stand-in scans the target's stack for `CFFIXED_USER_HOME=`
  and copies it back, logging `MONDRIAN Sandbox: <proc> container <path>`. Two
  different extensions received theirs on their own, `SiriTTSSynthesizer` and
  `MacinTalkAUSP`, both under `Data/PluginKitPlugin/<uuid>`. A process without
  the variable keeps `ENOENT` (0043's answer) instead of success with the buffer
  untouched: `launchd` asks about processes that have no container, and telling
  it they do hands it whatever the buffer held.
- **The appex's message is PlugInKit's, and its caller is in the cache.** The
  string sits at PlugInKit `+0x25697`, between
  `-[PKService launchContainingApplicationForPlugInNamed:]` and `missing data key
  in reply`, so the failure is the plug-in launch handshake, not the sandbox
  layer. The hook prints the raising stack as `image+0x...`; the frames land at
  `PlugInKit+0x18d5c`, `+0x4de0`, `+0x17f44`, `+0x5998`, `+0x4d44`, which are
  offsets inside the cache image (base `0x1aaf21000`), and `tools/dsc-va.py`
  names the image from them. The imported calls in those frames point into the
  stub region of the *main* cache file, which is truncated on this workstation
  (`nowhere (below every mapping)`), so the callee has to be named by hooking it,
  not by reading it.
- **The App Library's background is a capture nobody fills.** Measured
  2026-11-17: the library's background is one full-screen quad (program 21,
  blend off) over a material that asks the window server to capture the wallpaper
  group (`MTMaterialLayer`, `groupName` `WallpaperCaptureGroup`). On this port
  that capture is an empty surface, so the glass shows its memory: black on a
  fresh boot, and fine vertical stripes -- `(165,165)` then `(8,8)` per four
  panel pixels -- when the memory held something. A picture inserted behind the
  home screen does not show: the quad is drawn above it.
  The picture the backdrop does receive arrives with the wrong label: a colour
  bitmap four bytes a pixel (`f47c5b`, `68a4d9` at the sampled points) whose
  colour space says monochrome, which CoreAnimation hands to the GPU one byte a
  pixel. That mismatch turns any picture into the same stripes, so both ends are
  fixed in `tools/mondrian-ui-hook.m`: `mondrian_wall_relabel` gives such a
  bitmap its real colour space, and `mondrian_layer_set_contents` applies it to
  the pictures the UI sets.
  What the library shows today is drawn, not captured: the wallpaper is a still
  picture generated in the hook (720x1600 gradient), painted as the first
  sublayer of `SBHLibraryPodFolderView` (dimmed) and of `SBRootFolderView` (full
  strength), and refreshed every two seconds because the views are rebuilt.
  Measured on the glass: the library is a smooth gradient with no stripes and no
  black. Files `/private/var/vm/mondrian-nolibrary` or `-nowallpaper` holding `0`
  turn either one off, for an A/B with no build and no boot.
  Not worth repeating: setting `allowsInPlaceFiltering`, `allowsSubstituteColor`
  and `disablesOccludedBackdropBlurs` to `NO` on every backdrop layer turns the
  grey into black with a white blob; hiding `SBHomeScreenBackdropView` (the only
  `*Backdrop*` in `SBHomeScreenView`) leaves the stripes.
- **The App Library's cards are drawn by the port.** Measured 2026-11-18 with the
  card dump (`/private/var/vm/mondrian-cards`, off at `0`): every card is an
  `_SBHLibraryPodIconView` 170x184 in `_SBHLibraryPodIconListView` with **one**
  child, an `SBFTouchPassThroughView` of the same size, two sublayers, no
  `MTMaterialView` anywhere and no `backgroundColor` on any of them. So the grey
  square is the card layer's own `contents`, and on three of the four cards there
  is none -- which is why they showed their tiles on bare wallpaper.
  The model is a chain: the card's `icon` is an `SBHLibraryPodCategoryIcon` whose
  only accessor is `-category`, and `SBHLibraryCategory -icons` returned one to
  four `SBApplicationIcon`s. `tools/mondrian-ui-hook.m` composes those into one
  bitmap (`mondrian_card_picture`, tile clip `CGPathCreateWithRoundedRect` at
  0.2237 of the tile, or they come out as squares) and hangs it on the card as a
  sublayer of a card layer it owns: `backgroundColor` 82/93/107 at 0.97, read off
  the one card that drew itself, `cornerRadius` 0.16 of the side, `masksToBounds`.
  Verified on the glass: four cards each with their material and their icons,
  SpringBoard's pid unchanged for 30 s with the library displayed.
  The pass is switched by `/private/var/vm/mondrian-cardspaint` (on unless the
  file holds `0`). It was not the source of the `CRASH SpringBoard` records;
  the section below has what those were.
  **Do not paint the card into the tiles' bitmap.** That version (one bitmap with
  a filled rounded rect under the tiles) is the one whose boots crash-looped
  SpringBoard the moment the library opened -- pid changing every few seconds,
  `CRASH SpringBoard` at a wild address. Tiles-only and separate-layer both ran
  with a stable pid in the same session. Correlation, not proof: keep the card a
  layer of its own, which is also what iOS does.
- **`fps 0` means nothing was presented that second, not that the UI is dead.**
  Measured 2026-11-18: `MONDRIAN FB: fps 0` and `panel 0/60 sampled ticks
  changed` both read while the phone was responsive with the library on the
  glass, because a still screen produces no frames at all. Read the meter while
  the screen moves: two drag windows between pages reported `fps 49, 60, 45` and
  `fps 55, 52, 46, 44, 46` second by second, and the per-tick histogram in one of
  them `tick rec0 14 rec1 44 rec2 2` -- 46 of 60 ticks carried a frame, which is
  the number to compare against 60. Measured again 2026-11-18 on a steady boot
  (SpringBoard pid unchanged) with a sustained horizontal drag: `fps 47, 48, 49,
  50, 51, 54, 59`, `present 46 to 60/s drop 0` and `panel 46/60 … 59/60 sampled
  ticks changed`, with `copy avg 2.0 to 2.3 ms` per frame.
  The CoreAnimation counters are **not** a frame meter: `ca begin 0 commit 0 slow
  0 display 0 loop 20 in 1 s` was measured while that dragging was happening.
  `+[CATransaction begin]`/`+commit` and `-[CALayer displayIfNeeded]` are not on
  the path CoreAnimation takes internally; `loop` only proves the main run loop
  is being serviced. Use `/private/var/vm/mondrian-ca` (a file, `0` turns it off)
  for the run-loop number and the framebuffer meter for frames.
  The dump is armed by writing a number into `/private/var/vm/mondrian-deep` (a
  new number buys one dump, four a process) and read out of the ring.
- **Which apps open, and what they draw.** Measured 2026-11-18 on the
  `04:27:29` kernel, each app launched from its icon and left eight seconds:
  **Settings** draws its whole list -- title, Sign in, Airplane Mode, Wi-Fi
  (Off), Notifications, Sounds, Focus, Screen Time, General, Control Center,
  Display & Brightness, Home Screen, Accessibility, Wallpaper, Siri & Search,
  Passcode, Emergency SOS, Exposure Notifications, Battery; **Messages** draws
  the "Shared with You" welcome with its illustration and blue OK button;
  **Safari** draws its start page -- Favorites (Apple, Bing, Google, Yahoo),
  search field, toolbar. All three spawn (`exec MobileSMS`, `exec MobileSafari`)
  and composite real content, so LaunchServices, the icon model, the graphics
  stack and the fonts are all working. What comes up blank comes up blank for a
  reason of its own: **Phone** draws only the status bar and home indicator (no
  telephony stack), **Photos** does the same (its library services abort, below),
  and the **App Store** stops at `LOADING` because it needs the network. So a
  black screen after a tap is not one failure: read the ring's `exec` line to
  tell "never launched" from "launched and had nothing to draw".
- **The keyboard is not reachable with the synthetic touch.** Measured
  2026-11-19: the Messages search field and Safari's address field do not focus
  on a tap or a hold, and no keyboard window appears; the hook's own note says
  the keyboard's hit areas are not where its glyphs are drawn. A real finger on
  the panel is the next test -- the USB injector is not the touchscreen.
  `tap`/`swipe` take panel pixels (1440x3200) and `screen` returns half of that,
  so aim with the runtime's frames, not with the picture: the hook prints
  `MONDRIAN UI: icon Settings live <base> frame 35,227 64x78` in points, and three
  times that is the panel box whose centre is `201,798`; the grid is 3 columns, so
  the Photos icon above it is `201,420` and the dock row sits at `y 2990`
  (`420`, `720`, `1020` for Phone, Safari, Messages). One gesture at a time --
  the gadget's command thread is busy until the swipe finishes.
- **Photos runs once the hook is inside the app.** Measured 2026-11-18: the app
  execs and aborts `sig 6` at the same pc, lr and backtrace on every launch
  until `MobileSlideShow` is both injected (`xnu 0368`) and inside the hook's
  probe gate, and then it draws the What's New screen, then its own `Library`
  tab with `No Photos or Videos` and the four tabs, and stays alive. The abort
  was not an Objective-C exception -- the throw hook was armed and stayed
  silent -- and the call it dies in is `TCCAccessRequest`, whose denial aborts a
  client that has no usage description. assetsd's
  `assetsd requires TCCPhotosService access` is the same denial one layer in,
  through `-[PLPrivacy photosAccessAllowedWithScope:]`, which the hook answers
  now that the app and the daemons both carry it.
  What the port must not believe: tccd really denies. The original behind the
  interpose tuple answers 1 for `kTCCServicePhotos` while `SecTask` reads
  `com.apple.private.tcc.allow` through the same process's audit token
  (`MONDRIAN SEC`: `audit present`), so the denial is tccd's, not the kernel's.
  And a `dlsym` for `TCCAccessPreflight` returns the interposer: a probe that
  reads the symbol reads its own shim (`mondrian-tccok`) and calls it the OS
  answer. Use `mondrian_tcc_preflight_interpose.replacee`.
  The stand-in is on by default, so a restored root needs no seed: it answers
  the preflight, the audit-token check and `TCCAccessRequest` for every service,
  and `/private/var/vm/mondrian-tccoff` (any content) turns it off for an A/B.
  Measured 2026-11-18 on a boot with no `wfile` at all: pressing the Photos icon
  opened the app and it reached its Library tab, with `standin 1` in the ring.
- **A synthetic tap is a hold, and the home screen ignores it while it settles.**
  Measured 2026-11-18: `tap x y` sends down, down, up inside one frame and iOS
  drops it; `swipe x y x y 140` is the same point held 140 ms and works -- it
  opened Search, dismissed dialogs, answered the Photos onboarding, and on a
  settled home screen a 200 ms hold on the Photos icon opened the app. What does
  not work is a press while the home screen is still setting up: the widgets read
  `Waiting...` and the icon view does not react, so read a screenshot first
  (`No content available` in the Photos widget is a home screen that will
  respond). The host launcher stays as the deterministic path: write a bundle id
  to `/private/var/vm/mondrian-open` and the hook in SpringBoard calls
  `-[LSApplicationWorkspace openApplicationWithBundleID:]`, which answers 1 only
  while the device is unlocked, and every rewrite of the file is a new request.
- **A private selector called unguarded in a constructor is a SpringBoard crash
  loop.** Measured 2026-11-18: a probe that called `-[PLPrivacy _TCCForScope:]`
  without `respondsToSelector:` raised inside the hook's constructor, and
  SpringBoard re-exec'd 16 times with the same `sig 6`; a `grep 'exec
  SpringBoard'` in the ring is what tells that apart from a probe that hangs.
  Guard every private selector, and never `CFRelease` a value a getter did not
  own.
- **`csops` answers ERANGE when the buffer is small, not "no entitlements".**
  Measured 2026-11-18: the same probe read `-1 errno 34` for SpringBoard and
  5643 bytes for assetsd, because SpringBoard's blob is larger than the 8 KB the
  probe passed. A `-1` with errno 34 means the buffer, not the signature.
- **ReportCrash faults on its own work, and the loop is closed by not running
  it.** Measured 2026-11-18 on a boot whose UI was clean: 81 ReportCrash crashes
  in ten minutes, each `sig 11` at the same `pc` in `libc++`
  (`std::__fs::filesystem::path::lexically_relative`), reached from
  `libsystem_info` through a branch the dyld shared cache pre-links, so no
  interposer sees the call, with the faulting `this` unreadable and different
  every run. Every crash writes the report it then cannot process, so it feeds
  itself. The kernel's `CRASH` record already carries the `pc` and the frame
  chain, so the reporter is redundant on this port: the hook exits at load in
  that process unless the boot arguments carry `mondrianreportcrash=1`. Measured
  with it in place: 0 `CRASH ReportCrash` over a five-minute window, and 30
  `exec`/`exit status 0x0` pairs.
- **A switch written by `wfile` cannot be turned off again.** `wfile` creates the
  file root-owned, and the process that would delete it runs as the user, so a
  seed written once keeps applying (measured 2026-11-18: a stale
  `mondrian-reportcrash` brought the crash loop back to three crashes in a boot
  and no later write could undo it). A default-off switch that must never come
  back belongs in the boot arguments, where the next boot clears it.
- **A fault handler names the image, because the crash reporter cannot.** The
  hook arms `SIGSEGV`/`SIGBUS` for the probe targets and prints
  `MONDRIAN FAULT[pid]: sig <n> code <n> pc <image>+0x<off> far 0x<addr>`, which
  is how the `pc` above was named: walk the dyld image list and the segment
  tables in the handler, since the stack is already gone by the time a report is
  read. `SA_RESETHAND` restores the default action, so returning still dies the
  way the process would have.
- **The volume really is full, and `f_bavail` was zero with 164 MB free.**
  Measured 2026-11-18 with `xnu 0370`, which counts the allocation bitmap once per
  mount: `MONDRIAN HFSAUDIT: total 4194304 counter 55600 bitmap 63774 diff 8174`,
  so **249 MB free by the bitmap** and 217 MB by the counter `statfs` reports. The
  volume is full of files, not of lost blocks: a userland walk sees 12644 MB in
  159230 files and cannot enter 43 root-owned trees, and the same root's backup
  image carries only about 7.2 GB in a 7-Zip listing while `tools/hfs-audit.py`
  counts 2.4 GB free, so a walk undercounts by gigabytes and only the bitmap is
  authoritative. `/lost+found` is exonerated (`getattrlist`: one entry, no
  blocks). Measured 2026-11-19: `statfs` answered **f_bfree 41946 (164 MB) with
  f_bavail 3 (12 KB)** because the root mount withholds one percent of the volume
  as a free-block reserve (`HFS_MINFREE`). Every writer that honours the available
  count refused, PhotoKit answered `3305 (NotEnoughSpace)`, and 164 MB sat
  unusable. `0371` drops the reserve for this mount; `f_bavail` then equals
  `f_bfree`.
- **The free path leaked every range it did not own entirely, and the volume hit
  zero.** Measured 2026-11-19: deleting a 1 MiB file moved the counter from 0 to
  **24 blocks of its 256**, because `BlockMarkFreeInternal` abandoned the range at
  the first word that was not entirely allocated, returned `hfsNotAllocatedErr`
  and left the rest marked allocated, and `BlockDeallocate` skipped the counter on
  that error. Every log rotation therefore leaked what it had just written: the
  volume fell from 164 MB free to 0 inside one session, and a full volume is what
  makes app launches, catalog writes and log rotation fail. `0372` clears the bits
  that are set, counts them and adds that count to `freeBlocks`. The disagreement
  runs both ways -- deleting the 348 KB `mondrian-gl.dylib` afterwards returned
  **no** blocks because the bitmap already called them free while the file still
  held them -- so the allocation side is the next audit, not a settled story.
- **Photos has no library: TCC, then the library mode, then the volume.** Measured
  2026-11-18 with the app open and drawing its Library tab, in the order the
  chain was peeled: `+[PLPhotoLibraryPathManager systemLibraryURLIfResolvable]`
  answers nil while `isSystemLibraryURLDefined` answers 1;
  `+[PHPhotoLibrary authorizationStatus]` answers 2 (denied);
  `-[PLPrivacy _authStatusForScope:]` answers 0 (the raw TCC status, allowed) and
  answering 3 moves a change request from `PHPhotosErrorDomain 3310
  (AccessRestricted)` to the next layer; the app itself calls
  `+[PHPhotoLibrary enableMultiLibraryMode]` within eight seconds of loading
  (`isMultiLibraryModeEnabled` is 0 at load and the shared library then throws
  `Calling single library mode API while in multi library mode`), and with that
  switch kept from flipping the shared library accepts a change and answers
  `PHPhotosErrorDomain 3305 (NotEnoughSpace)`. That answer is about space and
  nothing else: `0370` puts the bitmap within 32 MB of the counter, `0371` stops
  the mount withholding 164 MB as `f_bavail` 0, and `0372` stops the free path
  leaking what it deletes.
- **The import works, the asset persists, and the picture draws through a client
  surface.** Measured 2026-11-19 on the restored volume: `library has 0`,
  `staged 1 at /var/tmp/mondrian-photo.png`, `free 2078 MB of 16384 MB`,
  `shared available`, `submitted via shared`, **`shared success 1`**; the Library
  draws one tile, the viewer opens on it with `Today` and its toolbar, and the
  next boot answers `library has 1`, so the asset is in the store and survives a
  reboot.
  The pixels are not the decoder's: `MONDRIAN DECODE[266]: 800x600 bpp 32
  quadrants 208,63,53 | 54,152,195 | 230,194,44 | 48,171,88`, and PhotoKit's own
  `PHImageManager requestImageForAsset:targetSize:200x200` answers a 200x150
  image with the same four colours. The layer is given a 640 x 480 CGImage with
  them too (`MONDRIAN LAYER[496]`), and CoreGraphics fills an IOSurface of that
  size with the same colours inside the app (`MONDRIAN CGSURF[425] ... drew 1`).
  What fails is the transfer into the render server: `0374` shows backboardd
  creating the surface for the tile (1105 x 1160 this run), taking one write lock
  and leaving it all zero, and the app never looks it up or locks it; the
  compositor's own `photo surface 43 ... seed 1` readback is zero in the four
  quadrants. `0375` puts the user stack on that sequence: one QuartzCore function
  creates the surface (`+0x140a10`), write-locks it (`+0x140a2c`) and unlocks it
  (`+0x140a40`) with no store in between, then takes a read-only lock at seed 1,
  and its callers are `+0x1848a0 -> +0x182078 -> +0xa3448 -> +0x6bafc ->
  +0x54bf8`. The `Failed to create IOSurfaceAccelerator` message is referenced
  from QuartzCore `+0x1e1c68/+0x1e3d7c`, off this stack; whether that path runs
  earlier is not measured. The tile and the viewer draw the four quadrants
  when the layer's contents is that filled IOSurface instead of a CGImage, which
  is what `tools/mondrian-ui-hook.m` does by default for CGImages of 300 x 200 and
  up whose width is a multiple of four; `/private/var/vm/mondrian-layercsurf-off`
  keeps the CGImage path for an A/B. The transfer inside CoreAnimation is still
  the open cause.
  A `deltree` of the trees a boot regrows frees nothing on this image: their
  catalog valence is 4, 9 and 10 and the plain readdir returns only the two dots,
  so the entries the valence counts are not in the catalog at all. Probes:
  `mondrian-import` prints the library answers at load and runs the import,
  `mondrian-doimport` alone submits one picture, `mondrian-du` prints the volume
  and the tree sizes, `mondrian-decode`'s readback is the `MONDRIAN DECODE` line.
  They reach the app through the exec probe, and an app does not exec under its
  bare name: it arrives as `/Applications/MobileSlideShow.app/MobileSlideShow`
  through a `posix_spawn` with no nameidata, so `0371` compares the last component
  and falls back to the executable's vnode name. The gate itself has to run before
  the probe-service branch, which returns for `MobileSlideShow`: that early return
  is why two sessions of "the import prints nothing" looked like a missing hook.
- **PhotosFileProvider still aborts `sig 6` in the PlugInKit check.** Measured
  2026-11-18: `PhotosFileProvider` and `fileproviderd` die at the same
  `mov x16, #328; svc #0x80` (`__pthread_kill`, a self-`abort`) while the app
  itself now draws its library, so the extension's container query is a separate
  defect from the app's TCC one.
- **Which hook is running, and whether it arrived whole.** The hook prints
  `MONDRIAN UI: hook tag cc56 uid <uid> prog <name> built <date> <time>` at load
  (`__DATE__`/`__TIME__`), and the ring holds several SpringBoard instances at
  once, so cut the log at the last tag before reading a probe: a line from the
  previous instance reads exactly like a probe that never ran.
  `tools/usb-ring.py wfile` now retries and only succeeds on `N of N bytes`; a
  partial delivery leaves a truncated dylib whose first functions still run,
  which is enough to make every later reading wrong.
  The step's liveness has its own line too: `MONDRIAN UI: lock watch <n> cycles,
  <m> steps, k with an app` says whether the watcher is posting and whether the
  posted step got past `UIApplication sharedApplication`. Without it, a dead
  watcher and a blocked main queue look identical -- and `steps 0` with `cycles`
  climbing is the main queue not draining at all, which is a wedged system, not
  this file (`mondrian_step_calls++` is the first statement of the step).
- **A rebuilt hook only reaches the phone through a kernel build.** Measured
  2026-11-18: the kernel carries the hook inside itself (`tools/gen-glblob.py`
  from `out/gpu/mondrian-ui-hook.dylib`, called by `tools/wsl/build-kernel.sh`)
  and writes it to `/private/var/vm/` while the root is being mounted, so the
  copy a `wfile` leaves behind is replaced by the boot's own -- and the tag line
  loses its `built` stamp, which is how it was noticed. `wfile` plus a SpringBoard
  restart is the cheap loop for iterating; a kernel build is what makes a change
  survive a reboot. Anything read after a reboot without that build is describing
  the old hook.
  Restarting SpringBoard is not free either: measured 2026-11-18, a
  `kill <SpringBoard pid>` was followed by `KABORT esr 0x96000047 far
  0xfffffe3c7c480000 pc 0xfffffe007c2dfc98 lr 0xfffffe0007584a68` on the console
  and a panel the console then drew over, which is a kernel fault and not this
  file's, but it costs the screen. Baking the hook into the kernel and booting is
  the clean way to get a picture.
- **Waking the panel is half of every failed unlock.** Measured 2026-11-18: the
  power key (`usb-ring.py key 0`) toggles, it does not wake -- pressed on a lit
  lock screen it blanks the panel, the framebuffer keeps the last image, so the
  screenshot looks like a lock screen that ignores every swipe and the next
  diagnostic is about the wrong thing. Swipe first; only press the key when the
  screenshot does not change, and then swipe again. With the panel lit,
  `swipe 720 3050 720 900 400` unlocks; `MONDRIAN FB: panel blank (power key)` /
  `panel wake (touch)` in the ring says which state it was in.
- **A boot that answers with another kernel really did fall back.** Measured
  2026-11-18: the ring is cleared at boot, so the first `Darwin Kernel Version`
  line is the kernel running, and `tools/wsl/cycle.sh` reads exactly that. When a
  RAM boot dies, `usb-ring.py prev` reads the *previous* boot's console out of
  userdata -- a panic flushes into it -- which is the only way to see why it
  died. The same day the RAM boot of the 19:21 kernel failed twice and then
  worked with no change at all to the image: retry (the slot is re-activated
  before every `fastboot boot`) before blaming what was built.
- **The framebuffer fetch extension has to stay offered.** Measured 2026-11-17
  by taking `GL_EXT_shader_framebuffer_fetch` away (write `0` to
  `/private/var/vm/mondrian-gl-fetch`, restart the window server -- an A/B with
  no build and no boot): the App Library's cards come out flat and light, so the
  extension is doing real work.
- **What the App Library transition costs, from the ring.** Measured 2026-11-17
  while swiping home -> App Library (the whole ring holds exactly two of these,
  both in that window): `readback 1440x3200 bgra invert 0 shared 0 mirror 0:
  read 9170 us` -- a full-canvas CPU readback, 18.8 MB, 9.2 ms -- then
  `2 textures refilled from IOSurfaces (23438 KB); 1 picture copied out` on a
  **52 469 us** frame, with `rate 10.9 frames in 1008 ms` at its side and frames
  of 101 ms and 131 ms in the same window. That is real, it is the stutter, and
  it is not the corruption: the picture copied out feeds the blur, and the blur
  samples whatever the panel held, console text included.
- **The copy-out path is a cliff, not a slope**: some frames take
  `1 textures refilled from IOSurfaces (18400 KB)` plus 10-13 ms of
  `copying out` for two or three draws. It shows up at boot and on app launch,
  not while scrolling.

## The renderer

The context line says it once per process:

    mondrian-gl: an OpenGL ES 3 context for CoreAnimation, by Mesa,
    off-screen (OSMesa): 4.6 (Compatibility Profile) Mesa 25.0.7; FD725;
    shaders 4.60

`GL_RENDERER` is `FD725`: Mesa's freedreno driver, rasterising on the Adreno.
OSMesa is only the window system (a memory surface, no `CAMetalLayer`). The
`waiting` half of the frame line is therefore real GPU time, or the cost of the
submit/fence pair, not a CPU rasteriser. `docs/COREANIMATION_GLES.md`'s "CPU
rasterization" note is stale.

## Three faults

### 1. A synchronous DSI write in the flush path freezes the compositor

Every boot that carried the hand-written DSI command-DMA brightness code (it
lived only in the local build tree, never in the series, and is gone) read
`mondrian-gl: rate 1 frames in ~5000 ms` and `present 0/s`, while the panel's
memory changed 0.2 times a second during a 2.5 s swipe: the transition advanced
one frame per five seconds. Five seconds is a timeout, not a frame cost.

The same tree rebuilt from `xnu/patches-mondrian` alone, with that code absent,
composites at **24 fps at rest and 60 fps while a swipe animates**, and the
glass follows: two captures of the panel a second apart differ in 35 000
pixels at rest, 942 000 during a 2.5 s swipe, and 0 once it settles. So CA's
commit/present loop, the render server and the panel copy are all healthy on
this hardware; what stops them is a blocking wait inside the flush or present
path -- in the measured case, the DSI command-DMA brightness write.

Treat `mondrian-gl: rate` as the frame-path probe: `N frames in ~1000 ms` is a
healthy compositor, `1 frame in ~5000 ms` means something in that path is
timing out. The UI hook prints the client side with `mondrianca=1`: one line a
second from `SpringBoard` and `backboardd`,
`ca begin N commit N slow N display N loop N`, where `loop` is a 20 Hz timer on
the main run loop and holds 20 for as long as that loop is serviced. A healthy
boot commits in bursts (3, 17, 1 a second) and the render server draws at 24 Hz
between them.

### 2. The system burns three cores while the UI is idle

`MONDRIAN CPU: busy` read a median of **48 % of 7 cpus** over 396 one-second
samples on the same boot, with SpringBoard, backboardd and launchd all in
`mach_msg` (idle). The burn is elsewhere:

| process | in one boot | note |
| --- | --- | --- |
| `xpcproxy` | ~800 execs | the on-demand launcher, ~1-3/s |
| `lskdd` | every ~1 s | exits and is relaunched, no error line |
| `watchdogd` | 39-100 crashes | SIGTRAP `BRK #1`, `pc == lr` in its own code, via libdispatch |
| `AegirPoster` | 48 crashes | extension check-in timeout |
| speech assets | 18 crashes | `SiriTTSSynthesizer`, `MacinTalkAUSP`, `KonaSynthesizer` |

110 crashes and ~800 execs in one boot is a process spawn every few seconds,
each one reading dyld and HFS+ through a synchronous UFS driver, plus a crash
report. It is also what a "slow static screen" is: a still screen legitimately
draws nothing, so the delay a finger feels is the wake/first-frame path waiting
behind this loop, not a low frame rate. Measure from a physical touch to the
first `present`, not in frames per second.

**Refusing the exec is what stops a job, not killing it.** `0316` refuses exec
with EACCES for a list of names, set from `mondriankill=quiet` (the built-in
list) and replaceable at run time with `execdeny NAME[,NAME]` and `execdeny off`
on the USB channel. A refused exec is reported as a SIGKILL, so the crash
reporter counts it: over two four-minute windows of one boot with the UI up,
the eight-name list (`calaccessd`, the three speech synthesisers, `watchdogd`,
`bluetoothd`, `fairplayd.H2`, `aggregated`) produced 97 crash lines against 25
without it, 24 of them for each refused name, and the exec count went up, not
down. The list is a loss once the UI runs; it stays as a switch.
`MONDRIAN PROC: exec N crash M denied K` prints every sample, so a boot reports
its own churn, and the counters are cumulative, which is what makes two windows
of one boot comparable without a second boot.

**`watchdogd` is the loop the list cannot touch.** 24 to 31 crash lines per four
minutes in both windows, i.e. one every ten seconds, with or without its exec
refused: it dies inside its own libdispatch callback (`pc == lr`) after being
started, so refusing the *next* exec changes nothing.

**It dies because the boot arguments are not in IOKit.** The signal is
`sig 5 code 0x600000001` at `watchdogd+0xb620`, which is the `brk` after its own
`__os_crash("could not retrieve device boot-args")`: `watchdogd` reads
`IODeviceTree:/options` through `IORegistryEntryFromPath` and
`IORegistryEntryCreateCFProperty("boot-args")`, and this port publishes no
NVRAM node, so the lookup fails and its failure path is a trap rather than a
fallback. `0336` attaches an `options` node to the device-tree root with the
kernel's command line as `boot-args`; nothing writes it back, which is what an
NVRAM controller would be for. Measured, same four-minute window: watchdogd
went from 24-31 crash lines to 4, and the boot's own total from
`exec 1301 crash 210` to `exec 629 crash 59`. The four that remain report a pc
inside its `os_log` wrapper (`watchdogd+0xa620`), not the `brk` at `0xb620`, so
they are a second failure of the same daemon and not this lookup. A crash at
`+0xb620` means the `options` node or its `boot-args` property is missing again.

### 3. The frame path is marginal

Even with a quiet system, the median frame is 11.0 ms and a scroll's extra
draws push the p90 past the period. This is the real cost once 1 and 2 are
gone; the levers are the draw count and the copy-out path
(`glflushdraws`, `glcopy`, `glfetch`), not the panel.

Measured with a CoreAnimation animation as the load (`mondrianunlock=1
mondriananim=1`, the probe square moving on the render server's clock): the path
holds **60 presents a second**, `copy avg 3.0-3.2 ms` (max 5.5), `late avg
3.5-3.8 ms` (max 16.6 once a window), `vsync avg 16.666 ms` with `over17` 5-7
and `drop 0`. Driving the same square from the display link instead
(`mondriananim=2`) moves nothing: the layer attaches to the key window
(`probe attached (480x1067, key 1)`) and no `probe moves` line ever appears, so
the client-side commit path is not reachable for a measurement until that is
fixed.

### 4. The UI can stop presenting, and then it stays dark

Two ways into the same end state: a lost compositor, which is still open, and
the idle blank, which `0342` closes.

Opening Safari brings up its window with `google.com` in the address bar and a
black page, `MobileSafari` exits 0x9, the `com.apple.WebKit.WebContent` helper
execs again, `pipelined` crashes, and from there `MONDRIAN FB: present 0/s` with
`touch 0/s` while SpringBoard keeps its heartbeat and does not crash. Treat a
black panel with a live ring as this state, not as a dead kernel: the USB channel
answers, and only a reset leaves it. The ring is what to read, and
`MONDRIAN FB: present`/`ev` are the two numbers that name it.
Measured 2026-11-19: the black page reproduces, but the home gesture still
presents, so the compositor is not lost in this boot; the `AA` menu opens and
draws white, and the address field does not focus under the synthetic touch. A
local page at `http://192.168.7.1:8000/` opens through `mondrian-open` and loads:
the host's HTTP server logs the page's icon GETs from 192.168.7.2, `pipelined`
exits 0 and no WebContent crash appears -- and the page still draws black. The
network is therefore not the cause; WebKit's page does not reach the glass,
which is the same server-side surface path as the Photos picture. The URL path
uses `LSApplicationWorkspace openURL:withOptions:`; the `UIApplication openURL:`
variant aborted SpringBoard in a loop (sig 6, libc++abi terminate) because the
`mondrian-open` thread is not the main thread.

The idle path had a second cause and it was ours. Until `0342` the driver
painted the framebuffer black when the blank fired, and the wake lived inside
`present()`: by then iOS has dimmed and stopped its own display link, so a tap
is delivered (`MONDRIAN HID: touch 0 down`) and produces **no present at all**.
Measured on a still lock screen: `panel blank after 30 s`, no wake line,
`present 0/s`, `panel 0/60 sampled ticks changed`, and the panel read 0.0 on
every capture afterwards -- the black paint had destroyed the only frame it
could show. The fix switches the panel off with DCS `0x28` (its RAM keeps the
image) and back on with `0x29` from the tick, so the wake needs no frame.

## Measurement traps

- **A corrupt iOS root looks exactly like a compositor fault.** Measured
  2026-11-17: `hfs_mark_inconsistent: Runtime corruption detected on iOSRoot`
  31 268 times in one boot. Two consequences that read as other bugs: the ring
  is 4 MiB and the repeated line fills it, so the early boot lines are gone and
  the log looks like it simply never printed them; and SpringBoard's main thread
  stops draining its queue (`MONDRIAN UI: lock step stuck; reposting`) with
  `fps 0`, `touch 0/s` and a panel that keeps its last image. That is
  indistinguishable, from the ring alone, from a display that slept or a
  compositor that hung, and a reboot does not clear it -- the forced `fsck`
  still leaves 1357 marks in the next boot. Check `hfs_mark_inconsistent` first
  in any boot that stops presenting, and restore
  `backup/ios-root-repaired.simg` when it is there.
- **A verified-clean root degrades because a catalog record can claim more bytes
  than the blocks it owns.** Measured 2026-11-18:
  `backup/ios-root-repaired.simg` expanded and checked with `fsck.hfsplus`
  ("appears to be OK"), written to `userdata`, and the first boot on it already
  produces them: `knowledgeC.db-shm` at 32768 bytes with **one** block, and a
  fresh 37-byte file with **none** every boot (a new cnid each time, so they are
  created then). Each such record fails `hfs_getnewvnode`'s size-versus-blocks
  check, which returns `EINVAL` and calls `hfs_mark_inconsistent` -- ~9 000 marks
  a boot, the number that decides whether the screen keeps presenting (see the
  first bullet of this section). Two paths make them:
  `ExtendFileC`'s deferred allocation (`kEFDeferMask`) grows `ff_size` and
  `ff_blocks` together without touching the disk; when the reservation is given
  back for a real allocation (`ff_blocks -= loanedBlocks`,
  `ff_unallocblocks = 0`) and that allocation or its extent record fails, the loop
  breaks with the size advanced and the blocks missing, and
  `hfs_prepare_fork_for_update` -- the last gate before `cat_update` -- only had
  its fast path look at invalid ranges, so the record went to disk as is. `0365`
  makes that fast path require the size to fit the blocks, so the existing trims
  cap it. Separately, `TruncateFileC` assigns `ff_blocks` *before* it frees and
  leaves through `ErrorExit` on the first failed `BlockDeallocate`, and
  `BlockMarkFreeInternal` reported a range that was already free as `EIO`, the
  code for a real read or write failure, marking the volume on the way out: a fork
  whose blocks were already free ended with a zeroed count and its extents still
  listed (`write id=84595901 size 850 blocks 0 extents 4012768+1, was blocks 1`
  next to `free 4012768+1 asked by mobileassetd`). `0363` gives that case its own
  code and finishes the truncate: measured, the failed frees fall from **275 in
  one boot to 4 in the next**. Neither can repair a record already on disk, because
  the check refuses it with `EINVAL` before anything can open it -- and a file that
  cannot be opened cannot be written back into shape. `0364` clamps that descriptor
  to the bytes its blocks can back before the check runs, so the file opens at its
  real length and the next `hfs_update` stores it. Measured with all three in
  place: **0 marks and 0 bad vnodes in two consecutive boots**, no record written
  with a size beyond its blocks (`writes 0`), and the failed frees still falling
  (275, then 4, then 9 of a different set). The 32768-byte records healed on disk
  during the first boot -- they are rewritten, so the clamp is stored -- and what
  remains is four small files with a size and no blocks that nothing writes; they
  are presented empty on every boot and mark nothing. `0355` flushes the root with
  `MNT_WAIT` before `reboot`/`poweroff`, which keeps a hard reset from adding to it.
- **`fsck` does not look for two forks claiming one block, and only an audit can
  say whether there are any.** `fsck.hfsplus` compares the bitmap with the *union*
  of every fork's extents, which passes when two files overlap. Measured
  2026-11-18 with `tools/hfs-audit.py` on the original dump and on the repaired
  image, byte for byte the same numbers: 0 overlaps, 0 records whose size exceeds
  their blocks, and the bitmap's free count equal to the header's. The extents
  overflow file does hold 3 extent records past the end of their fork, left by a
  truncate that failed to delete them, but `SearchExtentFile` stops at the fork's
  `totalBlocks`, so the kernel never reads them and they are not a defect. Reading
  them anyway invents overlaps with whichever file owns those blocks today -- an
  earlier version of the tool reported 52 that way. Keep the `totalBlocks` filter,
  and keep a running end when sweeping: comparing each extent with the one before
  it misses the nested claims. The tool is the check, in seconds and without a
  boot: bitmap against the header, overlaps, and sizes against blocks.
- **`panel 0/60` does not mean "not presenting".** It counts sampled ticks that
  changed, so a still screen reads 0/60 too -- a lock screen with the clock, the
  date and the camera button, captured 191 s into a repaired boot, reads 0/60.
  The proof that nothing is being presented is the *capture*: the Apple logo of
  the bootloader, i.e. the last image the panel was given, kept while SpringBoard
  runs (`SMP` lines keep counting). Measured 2026-11-18 on a root with 12 000-27 000
  marks: logo, 0/60, `present 0/s`; on the repaired root, with 2 500 marks: the
  lock screen draws. So the number of marks does not decide presentation either;
  the capture does, and `grep -c hfs_mark_inconsistent` only says how far the
  volume has drifted.
- **Measure the glass, not the counters.** `tools/usb-ring.py fps N` hashes
  eight panel rows over the ring about 30 times a second and counts the
  changes: that is the frame rate the eye gets. `fps` counts swaps, `present`
  counts the driver's own presents and `mondrian-gl: rate` only sees frames
  that end in the GL shim's flush, so each answers a narrower question. The row
  sampler counts only what moves: a still screen reads 0 while the compositor
  is healthy, so pair it with two `screen` captures and diff them (PIL is in
  the WSL image) before calling a boot frozen. It also under-reads a *small*
  moving layer: with the probe animation running, the driver counts `fps 60`
  and `present 60/s` while the sampler reports 7-14 changes a second, because a
  120 pt square crosses those eight rows only now and then. For an animation,
  read the driver's line and use the sampler only to prove the glass moves.
- **`stat()` is refused to a daemon in `/private/var/vm`; `access()` and
  `fopen()` are not.** Measured 2026-11-17: a probe armed by a file's mtime
  never fired -- in SpringBoard and in backboardd -- while the same file could
  be read at load. Arm a probe by comparing the file's *content* (a counter, or
  the rectangle itself), never by `stat()`.
- **Do not ask the display for a picture while SpringBoard is starting.**
  `CARenderServerRenderDisplay` exists and returns pixels, but calling it during
  startup leaves the phone on a black screen with a spinner, with SpringBoard
  alive and the compositor stopped; a respring does not clear it and only a RAM
  boot does. Take such a picture only on the running home screen.
- **The probe can kill the app it measures.** With `mondriananim=2` the probe
  moved with `-setPosition:`; that lookup fails on this runtime (the
  `mondriandnr=1` log reads `class CALayer sel setPosition present 0`, caller
  `-[MondrianLinkTarget tick:]`), and an uncaught exception inside a
  display-link callback takes SpringBoard with it -- which reads as "SpringBoard
  crashes when leaving the lock screen", not as a probe bug. The move now uses
  `-setFrame:`, the call the attach path already makes, and `mondriananim=0`
  keeps the probe out of the frame path entirely. Any code that runs per
  vsync must not be able to throw.
- **A still screen legitimately reads 0.** With the probe off, `fps` reads 0 at
  rest and 4-7 during a swipe while the compositor draws 24-43 fps; only two
  captures settle whether frames reach the glass.
- **`glwait=0` wedges the board.** Booted 2026-11-11 with `glwait=0`: the
  gadget enumerated and answered for about a minute, then went silent (RX 0, no
  ARP, `fastboot devices` empty) with the kernel still running. Recovering
  needs power + volume down, so only try it with the buttons in reach.
- **The power key toggles the panel.** Pressing it on a lit screen blanks it
  (`MONDRIAN FB: panel blank (power key)`) and a second press wakes it
  (`panel wake (power key)` + `panel on (dcs)`). Injected touches wake it as
  well: `tools/usb-ring.py tap` ends in `mondrian_hid_touch`, the same call the
  touch driver makes. Send both edges of a synthetic press (`key 0 down`, then
  `key 0 up`): a held key auto-repeats, and each repeat blanks again right after
  the wake.
- **Injected input does not drive SpringBoard's lock screen.** Measured on the
  lock screen: the unlock gesture (`swipe 720 3150 720 900 250`) leaves
  `panel 0/60 sampled ticks` with `1 present/s` and byte-identical captures, and
  a tap on a modal button ("Turn On Siri") does the same. The events reach the
  driver (`MONDRIAN HID: touch 0 down`), so it is SpringBoard that ignores
  them: a UI test must not assume it can unlock the device, and a transition has
  to be produced by the port (`mondriananim=2`) or by a boot.
- **A blanked panel keeps its last image.** `0342` switches the panel off and
  leaves its RAM alone, so a capture taken while it is off shows the frame from
  before the blank: an old clock, not a frozen compositor. A capture that reads
  0.0 means the panel rejected `0x28` and the black-paint fallback ran.
- **`cpufreq=0` disables the idle accounting** (`md_governor` gates the idle
  hook), so the busy figure reads 100 %. Keep `cpufreq=2` when the CPU line
  matters.
- **The sampler perturbs what it measures.** 200 stack samples at 1 ms, every
  5 s, in every injected process. It suspends the busiest thread 200 times per
  burst; it now starts only with `mondrian_ui_sample=1` (`mondrian-ui-hook.m`,
  `start_heartbeat()`), and the per-process CPU line replaces it as the cheap
  default.
- **The boot arg `mondrianfb_blank` is a fallback timer** (seconds without a
  present, 0 disables it), not the power key. The board cmdline carried 30 and
  now carries 0 while CoreAnimation renders through Mesa: the DCS blank resets
  the phone (`docs/MONDIAN_GPU.md`).

## Next probes

1. Done: the sampler is behind `mondrian_ui_sample=1` and the kernel prints
   `MONDRIAN CPU: top name(pid) N% ... in Nms` every 5 s
   (`mondrian_sample.c`). That line is the decisive measurement for fault 2:
   launchd churn, crash reporting, or a kernel thread.
2. **Brightness and the battery.** Done as `0305` and `0304`: the brightness is
   one DCS long write out of a fixed low page, sent by the tick behind a pending
   flag, and the battery is a 2 s thread that publishes an `IOPMPowerSource`, so
   the frame path gained a bool test. Check it at the panel with
   `usb-ring.py bl LEVEL` after a boot.
3. **The crash loop, if the UI still feels slow.** A boot with the probe off
   still logs ~160 crashes and ~800 execs: `watchdogd` (SIGTRAP `0x600000001`,
   `pc == lr` in its own libdispatch callback, every ~10 s), the speech trio
   (`SiriTTSSynthesizer`, `MacinTalkAUSP`, `KonaSynthesizer`) and `assetsd`.
   Pinning every cluster to its top row (`cpufreq=1`) does not move the frame
   cost (median 19.9 ms against 20.0 ms), so the governor is not the limit: the
   frame waits 13-15 ms for the GPU to finish drawing. Measure from a touch to
   the first `present` before optimizing draws.
4. A/B the frame path (`glflushdraws`, `glcopy`, `mondrianfb_fps=0`) on a
   screen something is actually animating. `glwait=0` is off the table (see the
   traps).
