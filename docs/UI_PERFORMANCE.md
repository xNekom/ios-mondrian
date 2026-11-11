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

### 1. Interaction can produce no frame at all

The injector's events do reach SpringBoard: a ring `swipe` pushes the home
screen into the App Library and back (screenshots 0.5 s apart show the
transition at different points, and the HID service logs `1 client`). What the
frames do not do is keep up: with a CoreAnimation animation running and a
2.5 s swipe in flight, the panel's own memory changes 0.2 times a second
(`tools/usb-ring.py fps`), and `present 0/s`, the compositor's rate and the
swap counters all agree. Two frames of that transition, half a second apart,
are enough to see it: the second still holds the black diagonal tear of the
first.

That is the same fault as the boot that never puts a frame on the glass
(`backboardd` commits a handful, then goes silent): not an input problem, and
not a frame-cost problem -- fast frames do not matter when the compositor
stops asking for them. The state to attack is `CA`'s own commit/present loop
while a client animates; the display links tick at 60 Hz throughout, in
`SpringBoard` and in `backboardd`.

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
report. This is also what a "slow static screen" is: with `fps 0` the screen
does not redraw, so the delay is the wake/first-frame path competing with this
loop, not a low frame rate. Measure from a physical touch to the first
`present`, not in frames per second.

### 3. The frame path is marginal

Even with a quiet system, the median frame is 11.0 ms and a scroll's extra
draws push the p90 past the period. This is the real cost once 1 and 2 are
gone; the levers are the draw count and the copy-out path
(`glflushdraws`, `glcopy`, `glfetch`), not the panel.

## Measurement traps

- **Measure the glass, not the counters.** `tools/usb-ring.py fps N` hashes
  eight panel rows over the ring about 30 times a second and counts the
  changes: that is the frame rate the eye gets. Everything else answers a
  narrower question -- `fps` counts swaps, `present` counts the driver's own
  presents, `mondrian-gl: rate` only sees frames that end in the GL shim's
  flush -- and all three read near zero while the panel visibly changes.
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
2. **Where the compositor stops.** Fault 1 is now measured at the glass, so the
   question is what ends `CA`'s commit/present loop while a client animates:
   the client commit rate (`CA::Transaction::commit` from the UI hook), the
   render server's frame work, and what it waits on between two frames. One
   boot with the hook counting commits per second in `SpringBoard` splits
   client from server; do not A/B the frame path until that is known.
3. Only then A/B the frame path (`glflushdraws`, `glcopy`, `mondrianfb_fps=0`)
   on a screen something is actually animating. `glwait=0` is off the table
   (see the traps).
