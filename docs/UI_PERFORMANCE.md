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
  untouched for 45 s: the ring carries `MONDRIAN UI: idle timer left armed
  (mondriankeepawake=0)`, then `MONDRIAN FB: panel blank after 30 s without a
  frame` (the seconds are `mondrianfb_blank`), then `MONDRIAN FB: panel wake
  (input)` on the first touch. Those three lines are the check: a missing blank
  line means frames never stopped (or the blank is disabled), and a missing wake
  line means the touch never reached the driver. Neither costs a rebuild.
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
  in an image that is meant to be used, and `tools/boards.py` carries the
  argument.
- **`/private/var/vm` keeps the previous boot's hook.** `kern_exec` injects the
  copy in `/private/var/vm` when it exists, and launchd and xpcproxy exec before
  the kernel rewrites it, so they load the previous build. A hook change reaches
  them one boot later; a build with no guard for launchd takes the boot down to
  two processes.
- **A panel capture is not a screenshot.** `usb-ring.py screen` reads the
  buffer the kernel console HUD (`0289`) writes, so rows such as `KABORT` and
  `P:` appear there even when the current boot logged none. The compositor's
  frame goes through its own surface (`MONDRIAN FB: layer 0 surface N`), so the
  capture shows the console, not the glass.

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
NVRAM controller would be for. A crash at that offset is this, not a watchdog.

### 3. The frame path is marginal

Even with a quiet system, the median frame is 11.0 ms and a scroll's extra
draws push the p90 past the period. This is the real cost once 1 and 2 are
gone; the levers are the draw count and the copy-out path
(`glflushdraws`, `glcopy`, `glfetch`), not the panel.

### 4. The UI can stop presenting, and then it stays dark

Measured twice. Opening Safari brings up its window with `google.com` in the
address bar and a black page, `MobileSafari` exits 0x9, the
`com.apple.WebKit.WebContent` helper execs again, `pipelined` crashes, and from
there `MONDRIAN FB: present 0/s` with `touch 0/s` while SpringBoard keeps its
heartbeat and does not crash. The same end state happens with no app involved:
after the panel blanks on its own, the screen stays black, `present 0/s`, and a
tap does not wake it -- the touch driver is fine (`MONDRIAN TOUCH: points r0 497
...`, `ev gap` grows) but nothing is dispatched (`ev 0/s`) and no frame is
produced, so the wake, which is driven by a present, never happens. Treat a
black panel with a live ring as this state, not as a dead kernel: the USB
channel answers, and only a reset leaves it. The cause is open; the ring is what
to read, and `MONDRIAN FB: present`/`ev` are the two numbers that name it.

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
