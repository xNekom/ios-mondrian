# GPU and boot time

The UI is CPU-rendered at 20-30 fps (`0114`, the software CoreAnimation
renderer). The other ios-sweet ports render through **Mesa/freedreno OpenGL ES
behind CoreAnimation's OpenGL ES renderer**; none of them has Metal. That is
the path this port follows.

## Reference stack

- **ios-topaz** (`MakrSas/ios-topaz`, a port of ios-sweet to SM6225, iPhone X
  iOS 16.7.16): kernel `RedwoodGPU` (an msm-style GPU client), `SweetSurface`
  IOSurface + `IOMobileFramebuffer`/`AppleCLCD` over the MDP; userland
  `userland/gpu` (`eagl.c`, `gl_osmesa.c`, `inject.c`, `bbd_wrap.c`) and
  `userland/mesa` (freedreno Darwin patches, `redwood-drm`). Patches
  `0900`-`0950`. Credits HackiOS (APSL 2.0 kernel, MIT user space).
- **HackiOS** (`oosexgang/hackios-xnu-kernel`, `hackios-xnu-userland`): Adreno
  650 through Mesa GLES, `gpu=1`, an image built with `GL=1`; no Metal.
- **Mesa freedreno** supports the Adreno 700 series (`a730`/`a740`, SM8450 /
  SM8550) since Mesa 24.3; Mesa 26.x keeps improving the a7xx.

## Mondrian delta

- GPU: **Adreno 730 (a730, a7xx)** at `3d00000.qcom,kgsl-3d0`, 220-900 MHz,
  `msm-adreno-tz`; `gpucc` clocks, GX GDSC and RPMh votes; GMU, SQE and ZAP;
  firmware `a730_sqe.fw`, `a730_gmu.bin`, `a730_zap.mbn` from the phone's
  vendor firmware. The references are a6xx: the a7xx registers, GMU/ZAP/SQE
  and the firmware are the new work.
- Display: today `mondrianfb` (the ABL framebuffer, 30 Hz). The GPU path needs
  the MDP/DSI and the IOSurface/`IOMobileFramebuffer` presentation (topaz's
  `SweetSurface`), with the iPhone X 1125x2436 canvas on the 1440x3200 panel.
  The panel is **120 Hz**, but the iPhone X userland and CoreAnimation run at
  60 (no ProMotion): 60 is the first target, 120 only by forcing the display
  link/ProMotion.
- CoreAnimation: the `eagl`/`gl_osmesa`/`inject` userland, the Mesa `FD730` and
  the AMFI/dyld policy that lets the GPU-backed GLES context load
  (`RedwoodWaitsForGpu` in topaz's 0109).

## Port steps

1. Import the topaz kernel GPU/display patches (`0900`-`0947`; `SweetSurface`
   `0131`-`0139`; the empty `IOAcceleratorES`; the surface/presenter work) and
   the `userland/gpu` + `userland/mesa` sources.
2. a730: `RedwoodGPU` (rename/adapt as `MondrianGPU`), the a7xx GMU/ZAP/SQE,
   the firmware, SMMU/pool/cache, the GPU clock and the GX vote.
3. Display: MDP/DSI/`AppleCLCD`, the mondrian 1440x3200 120 Hz panel, IOSurface and a
   presenter; move from the 30 Hz framebuffer cap to 60 (the iPhone X rate,
   topaz's 0941-0949), then 120 with ProMotion if the display link allows it.
4. Userland: Mesa `FD730` and the `mondrian-drm` interface, a `GL=1` image, the
   CA GLES, and the AMFI/dyld policy.
5. Boot time: see below.

## Boot time

The eight cores already start (`cpus=8`, all `PSCI CPU_ON rc=0`). The remaining
cost is CPU frequency, the boot CPU, the software renderer and debug I/O:

- **`bootcpu` / `cpufreq`**: HackiOS boots with `cpus=8 bootcpu=7 cpufreq=1`;
  the mondrian series has neither. The boot CPU is 0 (a little core) and the
  CPU OPPs are not set from XNU. HackiOS has `hakios.cpufreq.c` (EPSS: base,
  a LUT at +0x100 and PERF_STATE at +0x320; the top row per domain with our
  cores) and `loader_return.c` (`bootcpu=7`, the big core). The live SM8475
  tree has `qcom,cpufreq-hw-epss` at **0x17d91000/0x17d92000/0x17d93000**,
  `qcom,lut-row-size=4`; HackiOS's own base is 0x18591000, so only the base and
  the domain table change. The topaz 0094 is the SM6225 variant. Port both.
- **`IOAcceleratorES`**: topaz's 0138 (an empty `IOAcceleratorES`) saves ~30 s
  at every backboardd start; check what the mondrian's `0114` publishes.
- **Display refresh**: the topaz 0941-0949 add the vsync/presenter, direct
  frames and 60 Hz; today `mondrianfb_hz=30` (the panel itself is 120 Hz).
- **Release kernel**: `KERNEL_CONFIG=RELEASE` currently dies on the `iig` trap
  (`DriverKit/OSObject.iig.cpp: no member named 'kernelContent' in 'IORPC'`):
  the new `OBJROOT` regenerates the stubs with the modern `iig`. HackiOS ships
  `xnu-deps/` with a pregenerated `OSObject.iig.cpp`, `gen-iig-stubs.py` and a
  host `iig`; use those (or copy the generated `DEVELOPMENT_ARM64_MONDRIAN`
  `iokit` stubs) instead of the SDK's `iig`.
- **Debug I/O**: `serial=0`, no `debug=0xc`, no `-enable_kprintf_spam` for
  normal boots; the `FB: swap`/HID/sampler logs go to the ring.
- **First boot**: a freshly flashed data volume needs one long first boot to
  create the containers and the `mobileactivationd` data ark; later boots reach
  the lock screen. Do not reflash to change a dylib: update it in place.
- **GPU**: once the CA runs on the GPU, the boot/lock screen drawing moves off
  the CPU too.

## Milestones

1. GPU memory, command submission and the Mesa `FD730` context.
2. A CoreAnimation GLES frame through the GPU.
3. The MDP/IOSurface presenter and 60 Hz.
4. GPU clock above 600 MHz with the GX vote.
5. `bootcpu`/`cpufreq`, the release kernel, and the boot-time measurements.

Until then the CPU path remains the working baseline (home screen, Settings,
touch).
