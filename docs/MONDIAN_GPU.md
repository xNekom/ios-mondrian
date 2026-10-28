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

- GPU: **Adreno 730 (a730, a7xx)**, `qcom,gpu-model` **Adreno730v3**,
  `qcom,chipid 0x7030002`, `qcom,ubwc-mode 4`, at `3d00000.qcom,kgsl-3d0`;
  OPPs from 220 to 862 MHz (pwrlevel 0 = 0x33611380), `msm-adreno-tz`.
  The live tree (measured, not guessed):
  GPU `0x3d00000`+0x40000, GMU `0x3d68000`+0x37000 (`qcom,gen7-gmu`, PDC at
  `0xb290000`, GMU ao at `0x3d40000`, HFI IRQ 304, GMU IRQ 305), GPUCC
  `0x3d90000`+0xa000, GCC `0x100000`+0x1f4200, SMMU `0x3da0000`+0x40000
  (TCU `0x3de6000`, `qcom,adreno-smmu`, 21 context banks, 24 SMRs, 3-level
  tables), CX GDSC `0x3d99108`, GX GDSC `0x3d9905c`, GX domain `0x3d99504`,
  GX reset `0x3d99058`, ZAP region `gpu_microcode_region` at `0x8b91a000`
  (8 KiB). kgsl IRQ 300, frequency-limiter IRQ 286. Firmware:
  `a730_sqe.fw`, `a730_gmu.bin`, `a730_zap.mdt/.b02` from the vendor
  firmware. The references are a6xx: the a7xx registers, GMU/HFI, ZAP and
  SQE preamble are the new work.
- Display: today `mondrianfb` (the ABL framebuffer, 30 Hz). The GPU path needs
  the MDP/DSI and the IOSurface/`IOMobileFramebuffer` presentation (topaz's
  `SweetSurface`), with the iPhone X 1125x2436 canvas on the 1440x3200 panel.
  The panel is **120 Hz**, but the iPhone X userland and CoreAnimation run at
  60 (no ProMotion): 60 is the first target, 120 only by forcing the display
  link/ProMotion.
- CoreAnimation: the `eagl`/`gl_osmesa`/`inject` userland, the Mesa `FD730` and
  the AMFI/dyld policy that lets the GPU-backed GLES context load
  (`RedwoodWaitsForGpu` in topaz's 0109).

## Measured bring-up state

- **CX**: `gpupower=1` clears `SW_COLLAPSE` at `0x9108` and the hardware
  status at `0x953c` goes to `0x80001fe0`: CX is on. The kgsl-SMMU answers
  `idr0 0x2f0406`. A normal boot is untouched (`gpu=0`).
- **Clocks**: the GCC GPU gates are on (`0x62000` bits 15/16, `0x81010`,
  `0x81018`), the GMU RCG reads `0x505` (GPLL0/3 = 200 MHz), the HUB RCG
  `0x507` (GPLL0/4 = 150 MHz) with `CMD_ROOT_EN` set, but the GPUCC AHB
  branch (`0x911c`) still reads 0 and every GMU register reads
  **`0xdeafbead`**: the sentinel for a block that is not clocked.
  `GENERAL_9`/`GENERAL_10` reads hang. Root cause: the vendor's
  `gpu_cc_hub_clk_src` carries `HW_CLK_CTRL_MODE`, so the **hardware
  (AO/RPMh) owns the hub clock**; the CPU-side enable is a no-op and the
  hub only runs once the GPU power state is voted in RPMh (`gfx.lvl`,
  `cx.lvl`, `mx.lvl`). The vendor's `gen7_gmu_first_boot` runs
  `kgsl_pwrctrl_enable_cx_gdsc` -> `gen7_gmu_enable_clks` (gmu_clk and
  hub_clk rates + `clk_bulk_prepare_enable`) -> firmware -> register
  config -> `CM3_SYSRESET=0` -> PDC/RSC -> HFI, with the rail votes from
  `gen7_build_rpmh_tables`/`gen7_complete_rpmh_votes` done by pwrctrl.
  Next: port those RPMh votes (the touch driver already talks to cmd-db)
  before the clock enable, then the firmware load.
- **GMU gen7 map** (`gen7_reg.h`, not the a6xx one): `CM3_SYSRESET 0x1f800`,
  `FW_INIT_RESULT 0x1f81c`, `HFI_CTRL_STATUS 0x1f980`, `HFI_CTRL_INIT
  0x1f986`, `QTBL_ADDR/INFO 0x1f985/0x1f984`, `CM3_CFG 0x1f82d`,
  `GENERAL_8/9/10 0x1f9cd/0x1f9ce/0x1f9cf`, `ITCM 0x1b400`, `DTCM 0x1c400`.
- **Firmware**: `/vendor/firmware` carries `gmu_gen70000.bin` (57 KiB)
  only; `a730_sqe.fw` and `a730_zap.mdt` (what the vendor dmesg asks for)
  are not there and have to come from the stock ROM or `imagefv`.
- **Next**: port the vendor clock order (`kgsl_pwrctrl` enables the GCC
  AXI clocks and the GPUCC hub/AHB branches; ours only touches GPUCC), then
  the GMU firmware blocks (`{addr,size,type,value,data}` into ITCM/DTCM),
  `CM3_SYSRESET=0` + poll `FW_INIT_RESULT` bit 8, `HFI_CTRL_INIT`, and the
  GMU SMMU context (CB5) for the HFI queue and the VRB.

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
