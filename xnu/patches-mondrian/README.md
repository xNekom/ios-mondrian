# The mondrian patch series

The XNU patch series for the **POCO F5 Pro / Redmi K60** (`mondrian`, Qualcomm
SM8475 / Snapdragon 8+ Gen 1). It is parallel to `xnu/patches/`, which stays the
working `sweet` series: different SoCs, and the patches are not
interchangeable.

The CI picks a series with the `board` input of `.github/workflows/xnu.yml`:

| board | series | machine config |
| --- | --- | --- |
| `sweet` (default) | `xnu/patches/` | `SWEET` |
| `mondrian` | `xnu/patches-mondrian/` | `MONDRIAN` |

## What is in here

| Patch | What |
| --- | --- |
| `0001`–`0002` | the machine config for SM8475 (ARMv9.0, 16 KiB pages, GICv3 with eight redistributors, no PAC) and `config/MASTER.arm64.mondrian` |
| `0003`–`0055` | the generic half of the sweet series: RAM disk root, mockfs, AMFI, HFS+, BearSSL, the console, the crash log, the HID services, the SMP and the iPhone identity |
| `0056`–`0062` | the page-size work (commpage, zone map VA, bootstrap VA zone, no physical timer write, framebuffer alias reservation) and the first UFS 3.1 root device (`0059`); `0058` went away with the 4 KiB software page size |
| `0063`–`0069` | boot diagnostics and the interrupt path: `bsd_init` trail, console beacon, EL1 timer interrupt |
| `0070`–`0082`, `0086`, `0090`–`0116` | the UFS 3.1 root device, its wake sequence, the write path (`0090`), the task name in an unclassified abort (`0091`), the console's 64-bit clear (`0092`), bounded key-store calls (`0093`), the duplicate-surface lookup backboardd needs (`0094`), the userland sampler (`0095`), persistent logging with post-root startup and readback verification (`0096`–`0097`), the iOS swap path and `/private/var/vm` (`0098`), the dump's comma-separated term list (`0099`), the log/sampler paced by the UFS write path instead of dead timeouts (`0100`–`0101`), the one-shot detailed sampler dump (`0102`), the writer woken by console output (`0103`), the dump's six-line tails (`0104`), the console tee at the funnel point (`0105`), the opt-in personas/display diagnostics (`0106`), the lost-wakeup/exit-log fix (`0107`), the `AMFI` dyld-policy answer (`0108`), the target-aware detailed-sample trigger (`0109`), timer/GIC register snapshots (`0110`), the CNTV IMASK correction (`0111`), per-daemon injection modes (`0112`), the sampler kept out of the console and UFS paths (`0113`), the display mode plus empty `IOAcceleratorES` that let CoreAnimation fall back to its software renderer (`0114`), the panel written through the console alias with the console paused without unmapping it (`0115`), and the vtimer PPI fix (active state, Group 1 modifier) with the timer/interrupt diagnostics (`0116`) |
| `0083`–`0085` | panel memory reservation, IOSurface/IOMobileFramebuffer presentation (`0084`'s colour-bar self-test is off since `0208`) |
| `0087`–`0089` | GIC remap after the VM takes over, `VFS_ROOT` errno before the panic, unsealed root accepted |
| `0117`–`0180` | the hardware bring-up after the display: the Goodix touch (TLMM, GENI SPI, 220 KB firmware, vsync reports), the GPU probe (GMU SMMU and firmware, HFI power tables, GX, the ARC votes), the `0173` timer arm, the boot bisect marks, the canvas CFData types, and the cmd-db/RSC mapping cache |
| `0181`–`0184` | the CP path and its SMMU context (`0181`), the `MondrianGPU` user client (`0182`), the surface wrap refusal (`0183`) and the inert `mondrian_gpu_uc_*` fallback when the local CP profile is absent (`0184`) |
| `0185`–`0202` | the submission path: the CP's SMMU ASID invalidate when the tables change (`0185`), diagnostics that survive a wedged CP (`0186`–`0188`), the GPU left stopped after a missed fence (`0191`), the draw-state expansion behind `gpunostate=1` (`0193`, `0195`), the doorbell written from its own thread and then defaulted back to inline (`0196`, `0197`), `gen7_start` + `CP_ME_INIT` behind `gpuinit=1`/`gpuinit=2` (`0198`), and the diagnostics that answer the wedged draw: `CB_FAR`/syndrome in the dump (`0199`), the latched-SMMU-fault clear plus a page-table walk for the faulting address (`0200`), and kgsl's IFPC/IB1LIST bracket, which is what lets the first draw fence (`0201`, behind `gpunomark=1`), and the submit-step markers plus `RBBM_STATUS` that say where a boot died (`0202`) |
| `0203`–`0216` | what made the first draw complete and then stay healthy: the bracket off by default (`0203`), kgsl's ring wrap with backpressure (`0204`), the `uc enter` marker (`0205`), a 512 KiB CP page-table region (`0206`), IOVA range reuse (`0207`), no colour bars over the boot logo (`0208`), the digitizer event marked display integrated so backboardd delivers it (`0209`), the kernel log painted on the panel with a page scroll (`0210`), GPU buffers allowed above the lowest 4 GiB (`0211`), a console painter the log cannot outrun (`0212`), that painting moved off the printf path into the log thread (`0213`), the console following the newest line and reporting its rate (`0214`–`0216`), and the GPU keepalive held around every register read by default (`0215`) |
| `0217`–`0230` | the frame path: the CP's page tables covering the whole IOVA window (`0217`), the console painting every line (`0218`), more than 64 buffers a submission (`0219`), the kernel installing the CoreAnimation dylibs at boot (`0220`), writing back only the buffers the CPU touched (`0221`), a cheaper ring clean and one rptr read a lap (`0222`), the wallpaper's poster extensions getting the UI library (`0223`), the CP proving it consumed the bring-up before the ring is published, the lap end published and waited for on wrap, and `cpstress=0` (`0224`), the ring clean keeping the low 14 bits of the 16 KiB page offset (`0225`), `gpuperf=N` moving the GMU's default perf vote off kgsl's 285 MHz (`0226`), real cache maintenance (`0227`), the off-by-default `BIT(27)` event bisect (`0228`), the off-by-default A725/A730 SP warm-up stream (`0229`), and the fix that points its nested IB at the PM4 stream at `iova+64`, not at the shader at `iova` (`0230`) |

| `0231`–`0252` | the surface and 2D paths: `RB_DONE` and the render target (`0231`–`0232`), surface IOVA and the 2D fill/readback probes with their spill, physical-address, scan and sysmem variants (`0233`–`0250`), submission timing (`0251`) and the sync-map limit (`0252`) |
| `0254`–`0263` | the measurement path: touch at 60 Hz (`0254`), the HID drag probe (`0255`), the framebuffer vsync selector and console pause (`0256`–`0257`), HID wake (`0258`–`0259`), the memory line, the selector log and the wired breakdown (`0260`–`0262`), and the digitizer event marked integrated (`0263`) |
| `0264`–`0266` | iteration and the ring: the userland hook carried as a kernel blob so a dylib change costs one kernel build (`0264`), the wedged-ring diagnostic that names the submission (`0265`), and the lap boundary closed the way kgsl closes it, with a 128 KiB ring and a fenced doorbell (`0266`) |
| `0267`–`0269` | the geometry and its cost: `BOOT_LINE_LENGTH` raised to 1024 so a long measurement cmdline is not silently cut (`0267`), the canvas scaled through a column map built once and a lookup-free 32/25 block of 16-byte stores instead of a 64-bit divide per pixel (`0268`), and the fps line split into `clean avg`/`scale avg` so the next optimisation has a number to aim at (`0269`) |
| `0270`–`0283` | the cadence: the part's report rates on the fps line (`0270`), the reports read on every look while a finger is down (`0271`), the canvas scale in 16-byte NEON lanes (`0272`), the interval between frames and the finer buckets (`0273`, `0275`), the vsync armed from a deadline chain and its clock printed (`0274`), one touch position per display tick (`0276`), a five-second-in-ten window without the panel copy and the point counts (`0277`, `0278`), the frame presented at the tick instead of on the renderer's thread (`0279`), the unattended drag (`0280`), the records each tick was handed (`0281`), two finished frames queued so a burst spreads over two ticks instead of holding one for two periods (`0282`), and the sweep's shape: horizontal, with the unlock swipe behind `mondriandragunlock=1` (`0283`) |
| `0284`–`0288` | the CPU and the tick: the four A510s levelled through `l2-access-penalty` (`0284`), the `IOMFBDisplayRefresh` property the window server paces its link on (`0285`), the touch tick sampled after the drain so one event comes out per tick (`0286`), UI-priority threads taking an idle X2 first (`0287`), and the publish moved to the first report of the wake with the report thread woken before the panel copy (`0288`) |
| `0289`-`0296`, `0298`-`0303` | what the live tree had and the series did not: the panic and fault report on the HUD rows, the secondary-core stage marks and the lock-owner panic (`0289`), the small-core scheduler made opt-in and its topology line (`0290`), the command-mode panel's per-frame CTL start and the host's panel capture (`0291`), the GPU buffer histogram and the on-demand `VMSTAT` line (`0292`), the USB gadget and the control channel (`0293`), the upstream-clang/SDK build gaps (`0294`), the final physmap with the framebuffer alias and the opt-in panel console (`0295`), the memory accounting that closed the window plus the `CONFIG_JETSAM` the config had left out (`0296`), the gadget re-arming its endpoints after a bus reset (`0298`), the EPSS governor that takes the idle clusters off their top row (`0299`), the touch edge bit that makes the home and app-switcher gestures work (`0300`), the SPMI poller behind the power and volume keys (`0301`), the black frame that takes the last picture off a sleeping command-mode panel (`0302`), and the panel that follows the power key and the finger (`0303`). The mass-storage patches (`0297`) are not in the series: the host enumerates the disk, but its first SCSI read never returns. |

`0085` is the IOSurface + IOMobileFramebuffer pair. Each patch's symptom and
the trap behind it are in `NOTES.md`. The series count in "Applying it" below is
`tools/check-patches.sh`'s `NN/NN` line, not a constant.

## Applying it

```
git clone --depth 1 --branch xnu-8796.141.3 \
    https://github.com/apple-oss-distributions/xnu.git xnu8796
tools/apply-series.py xnu8796 --series xnu/patches-mondrian --machine MONDRIAN
```

A patch that does not apply fails the CI run (the workflow's "No skipped
patches" step greps dxb's log), but it costs a run; the command above (or
`tools/check-patches.sh`) names it in seconds. Its `NN/NN` line
is the count for the current series. Two traps it catches: `git apply` rejects a hunk
that ends with added lines and no trailing context, and a patch touching a
staged source (HFS, BearSSL, libpthread) only applies after its staging script
ran; `NO_STAGE=1` makes `0036` fail for that reason alone. A *cancelled* job is
reported as `failure` too.

`tools/validate-repo.py` is stricter than `git apply`, and three of its
findings on this series are known and harmless: the prose preamble of `0087`
(its diff starts further down, which `git apply` accepts) and a hunk count in
`0060`. Every patch applies with `git apply`; CI validates the kernel build.

## What is still missing

The patches that talk to the sweet phone's hardware. They are listed in
`HARDWARE_PATCHES` of `tools/port-series.py`; `docs/MONDIAN_PORT.md` has the
work items:

* the dual-boot slot switch.

`tools/port-series.py` does the mechanical part of a port: it takes a patch from
the sweet series, renames the board identifiers, drops the context lines that
name something a not-yet-ported patch adds, and lists the hunks that need
hardware work.
