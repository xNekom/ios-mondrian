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
- **The App Library's icons are empty squares.** Measured 2026-11-18 with the
  deep dump (`mondrian-deep`) while the library was on the glass: the cards are
  `_SBHLibraryPodIconView` 170x184 inside `_SBHLibraryPodIconListView`, their
  layers report no contents, and `SBHLibraryPodFolderView` 480x1067 wraps them.
  The home screen's icons only exist because the hook paints the eight
  `SBIconView`s the home screen carried when it was probed
  (`mondrian_icon_force_artwork`); a card is a *folder* icon (a category's
  preview grid), not an application icon, so that pass skips it by design.
  What a card should show is a 2x2 grid of the category's own app icons, so the
  fix is to compose it: ask the card's `icon` for `icons`, take four application
  icons, load each app's AppIcon file and put four tiles in a view of ours over
  the card. That pass is not in the tree yet. The dump is armed by writing a
  number into `/private/var/vm/mondrian-deep` (a new number buys one dump, four a
  process) and read out of the ring.
  Two numbers that look like a dead UI and are not: `fps 0` and
  `panel 0/60 sampled ticks changed` were measured while the phone was
  responsive with the library on the glass.
  The step itself is the fragile part: `mondrian_lock_step` is posted by its own
  thread through `dispatch_async_f`, and a boot was measured where it ran once
  (it printed `lock screen gone` and the twenty-second icon tree) and then never
  again, with **no** `lock step stuck` line and no periodic `MONDRIAN WALL: dump`
  to show for it -- so the library came up striped with the fix loaded and idle.
  Count `MONDRIAN WALL: dump` lines before blaming the paint.
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
