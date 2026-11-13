# UI performance

What makes the phone feel slow, measured from the console ring. The frame
budget is only one of three faults: a static screen draws no frames at all, and
the system spends about three of its seven cores on a launch/crash loop. Which
fault a slow moment belongs to decides what to fix.

Every number comes from a ring dump (`tools/usb-ring.py dump`); the lines are
already printed by the kernel and the injector, so a measurement costs one boot
and no rebuild.

## The frame budget

`MONDRIAN FB: fps` prints once a second and `mondrian-gl: frame` every 20th
frame (and the first 40), both steered by boot args (`mondrianfb_fps=1`,
`glframes=1`). One steady-state boot (156 frames, home screen) gives:

| measurement | p50 | p90 | max |
| --- | --- | --- | --- |
| frame, `mondrian-gl` total | 11.0 ms | 19.8 ms | 37 ms |
| of which waiting for the GPU (`glFinish`) | 5.0 ms | 12.9 ms | 25.8 ms |
| of which Mesa command encoding (the rest) | 3.4 ms | 10.0 ms | - |
| draws per frame | 66 | 91 | 176 |
| kernel copy of the surface into the panel | 2.4 ms | 4.4 ms | 5.5 ms |

- **24 % of frames miss the 16.7 ms period** (37 of 156). The cost grows with
  the draw count, about 100 us a draw on the CPU and 40 us on the GPU, which is
  what a scroll or a blur pays for.
- **The panel side is healthy**: `vsync avg 16666 us`, `over20 0`,
  `present 55-59/s`, `drop 0`. The tick is not what drops frames.
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

### 3. The frame path is marginal

Even with a quiet system, the median frame is 11.0 ms and a scroll's extra
draws push the p90 past the period. This is the real cost once 1 and 2 are
gone; the levers are the draw count and the copy-out path
(`glflushdraws`, `glcopy`, `glfetch`), not the panel.

### 4. Opening Safari stops the UI

Measured on one boot: tapping the Safari icon brings up its window with
`google.com` in the address bar and a black page, `MobileSafari` exits 0x9, the
`com.apple.WebKit.WebContent` helper execs again, `pipelined` crashes, and from
there `MONDRIAN FB: present 0/s` with `touch 0/s` -- presents stop and so does
touch, while SpringBoard keeps its heartbeat and does not crash. The frame tick
shows gaps of 2-40 s. WebKit needs the GPU path this port does not have
(`docs/COREANIMATION_GLES.md`) and the UI never recovers: treat a Safari launch
as a way to lose the boot, not as a browser.

## Measurement traps

- **Measure the glass, not the counters.** `tools/usb-ring.py fps N` hashes
  eight panel rows over the ring about 30 times a second and counts the
  changes: that is the frame rate the eye gets. `fps` counts swaps, `present`
  counts the driver's own presents and `mondrian-gl: rate` only sees frames
  that end in the GL shim's flush, so each answers a narrower question. The row
  sampler counts only what moves: a still screen reads 0 while the compositor
  is healthy, so pair it with two `screen` captures and diff them (PIL is in
  the WSL image) before calling a boot frozen.
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
  (`MONDRIAN FB: panel blank (power key)`, DBV 0). Injected touches do not wake
  it: the wake comes from the touch controller's interrupt, which a HID
  injection bypasses. A host-driven test starts with the screen already on.
- **A blanked panel keeps its last image.** Screenshots then show a stale
  clock, not a frozen compositor.
- **`cpufreq=0` disables the idle accounting** (`md_governor` gates the idle
  hook), so the busy figure reads 100 %. Keep `cpufreq=2` when the CPU line
  matters.
- **The sampler perturbs what it measures.** 200 stack samples at 1 ms, every
  5 s, in every injected process. It suspends the busiest thread 200 times per
  burst; it now starts only with `mondrian_ui_sample=1` (`mondrian-ui-hook.m`,
  `start_heartbeat()`), and the per-process CPU line replaces it as the cheap
  default.
- **The boot arg `mondrianfb_blank` is a fallback timer** (seconds without a
  present, 0 disables it), not the power key. The board cmdline sets 0.

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
