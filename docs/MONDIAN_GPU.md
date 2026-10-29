# GPU and boot time

The UI is CPU-rendered at 6.4 fps (active seconds, max 23 with
`mondrianfb_fps=1` at 1440x3200, copy ~2.3 ms per swap; `0114`, the software
CoreAnimation renderer); a 900x2000 canvas reaches 9.3. The GPU probe and
GX add no frames yet. The other ios-sweet ports render through
**Mesa/freedreno OpenGL ES behind CoreAnimation's OpenGL ES renderer**; none of
them has Metal. That is the path this port follows.

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
- Display: today `mondrianfb` (the ABL framebuffer, 60 Hz). The GPU path needs
  the MDP/DSI and the IOSurface/`IOMobileFramebuffer` presentation (topaz's
  `SweetSurface`), with the iPhone X 1125x2436 canvas on the 1440x3200 panel.
  The panel is **120 Hz**, but the iPhone X userland and CoreAnimation run at
  60 (no ProMotion): 60 is the first target, 120 only by forcing the display
  link/ProMotion.
- CoreAnimation: the `eagl`/`gl_osmesa`/`inject` userland, the Mesa `FD730` and
  the AMFI/dyld policy that lets the GPU-backed GLES context load
  (`RedwoodWaitsForGpu` in topaz's 0109).

## Measured bring-up state

- **CX**: `gpupower=1` follows the vendor `PongAdrenoClocks.c` sequence:
  `CLK_DIS_WAIT=8` with `SW_COLLAPSE`/`HW_CONTROL`/`SW_OVERRIDE` cleared at
  `0x9108`, poll `0x953c` for `PWR_ON`, then `RETAIN_FF`. A normal boot is
  untouched (`gpu=0`).
- **Clocks**: GCC GPU gates (`0x62000` bits 15/16, `0x81010`, `0x81018`) and
  the GPUCC PLL0/PLL1 (LUCID_OLE) are programmed. The GMU RCG final value is
  `0x100602`, HUB `0x100603`, XO `0x100001`; the force-enable must be held
  until the branches are on (`0x9004`, `0x9144`, `0x93e8`, `0x913c`,
  `0x9148`, `0x911c` delayed, `0x7000`). The AHB branch `0x911c` reads 0 by
  design: the vendor marks it delayed and never checks it, so that readback
  is not the failure signal it was taken for.
- **GMU addressing**: the `gen7_reg.h` numbers are dword offsets from the
  GPU regmap base (`kgsl_regmap_region.offset`), so in the GMU window
  (`0x3d68000`) the byte offset is `word*4 - 0x68000`: `CM3_SYSRESET`
  `0x16000`, `FW_INIT_RESULT` `0x16070`, `HFI_CTRL_STATUS` `0x16600`, ITCM
  `0x5000`, DTCM `0x9000`. Reading `gmu+0x1f800` returns `0xdeafbead`; the
  real register reads 1.
- **GBIF and TCM**: `GEN7_GBIF_HALT` is GPU core word `0x3c45` (offset
  `0xf114`); the bootloader leaves `0x8` and writing 0 clears it. The TCM
  firmware blocks load and read back (ITCM first word `0x10007f80`), and
  `CM3_SYSRESET` reads 1. Do not write `SYSRESET=0` before the firmware is
  in place: an empty ITCM wedges the bus.
- **Firmware layout**: `gmu_gen70000.bin` is a list of
  `{addr,len,type,value}` blocks: ITCM `0x0` (`0x1dc`), the main 57 KiB code
  at `0x4000`, DTCM `0x10007f98` (`0x28`) and `0x10007fdc` (`0x18`). The
  `0x4000` block is not TCM: it needs the GPU SMMU and the external GMU
  memory at IOVA `0x4000`.
- **GMU SMMU**: the bootloader leaves `sCR0=0x2f0406` (global enabled, fault
  reporting on). The GMU node uses `iommus = <&gpu_smmu 5 0x400>`, so SIDs
  5/0x405. `UniXNU/Adreno740` `NativeAdrenoGmuMemory.h` gives the qualified
  layout: icache `0xffc000` at `0x4000`, dummy `0x4000` at `0x60000000`, log
  `0x4000` at `0x60004000`, HFI `0x4000` at `0x60008000`, debug `0x7000` at
  `0x60400000`, 4 KiB tables. Context: CBAR `0x1f300`, CBA2R 1, TCR2
  `0x38072`, TCR `0x80802020`, MAIR0 `0xff44`, SCTLR `0x127`, ASID 1,
  TTBR0 `(1<<48)|root`; stream SMR `(1<<31)|5`, S2CR = bank.
- **GMU boot**: the GMU needs **two** SMMU streams, SIDs 5 and 0x405 (the DT
  `iommus` mask 0x400 expands to both). With only SID 5 the CM3 start hangs
  the AHB; with both it reaches `FW_INIT_RESULT=0x100` in ~1.8 ms and
  `HFI_CTRL_STATUS=0x1`. The kernel then boots the UI normally. Pong's
  RSCC/PDC and TCM-retention writes are in the tree behind `gpurscc=1`; the
  successful boot did not use them.
- **Local firmware build**: `tools/gen-gmu-fw.py <gmu_gen70000.bin>
  <build>/bsd/dev/mondrian_gmu_fw.h` before building with `gmustart=1`. The
  header is generated from the device dump and is not committed; without it
  the kernel builds and prints `no gmu firmware built in`.
- **HFI power and GX**: the GMU ACKs PERF (id 4, 58 words), BW (id 3, 159),
  CORE_FW_START (14), the default vote (30, `gpu 2 bus 2`) and START10 with
  `err 0`; `oob_gpu` is held and GX reads `PWR_ON=1` (`gdscr 0xf8222800`,
  `gx hw 0x0`). `GEN7_GMU_GFX_PWR_CLK_STATUS` reads 0x0 (GX power and clock
  on) and the `gpu_cc_gx_gfx3d` branch 0x221 after START10.
  The tables come from the live cmd-db (`gfx/mx/cx`,
  SH0/MC0/ACV) and the 13 mondrian OPPs, the same data as Pong's
  `PongAdrenoPower.c`. A full boot with the tables and GX on reaches
  SpringBoard and the touch report thread; one 150 s boot measured 8.1 active
  fps (max 35) against the 6.4 (max 23) CPU baseline, so the userland is
  still the software renderer.
  The 8 MiB `io_submap` is the trap: `ml_io_map()` has no unmap and the touch
  command DB/RSC windows were re-mapped per lookup; `0179` caches both.
- **CP and its SMMU**: the bootloader leaves the CP at zero. `0181` (local
  `gpusubmit=1`) takes SMMU bank 0 for the user/lpac streams (SID 0/0x400,
  1/0x401), maps the 128 KiB SQE at 0x100000, the 32 KiB ring at 0x200000,
  the memptr at 0x300000 and the CP power-up list at 0x301000, loads
  `a730_sqe.fw`, runs the CP hardware init, starts the SQE and submits
  `CP_ME_INIT`. Three traps measured on the way: the first next-level table
  started at page 0, so the L1 entry pointed at the root (the GMU only
  worked because its leaf landed in the root's L3 slot; the CP's 0x100000
  faulted); the CP bank first shared ASID 1 with the GMU (the TLB is tagged
  by ASID); and `kmem_alloc_contig` returned a VA at a 4 KiB offset even with
  a 16 KiB mask and a 4 KiB physical run let the 16 KiB pmap round the PA, so
  the CP tables memset aborted (`far 0xfffffe0008026b000`,
  `esr 0x92000010`). The allocator now reserves the slack, aligns the VA by
  hand and asks for 16 KiB physical pages (`pnum_mask=3`).
- **The GPU boots trusted and the CP bases need one 64-bit store.**
  `RBBM_SECVID_TRUST_CNTL` reads 1, and writing 0 aborts the CPU (the secure
  monitor owns the register). `CP_SQE_INSTR_BASE` and `CP_RB_BASE` are 64-bit
  registers: two 32-bit stores leave the bootloader's `0xe000` in the high
  word (a read there is not an error, but the address then becomes
  `0xE000_0000_0000 + low`), while a single 64-bit store latches the whole
  value and the high word reads 0. Write them with `mondrian_gpu_write64`, as
  `a7xx_hw_init` does, and the CP fetches the low window (`0x100000`).
  The earlier `0xe000` read came from 32-bit stores, not from a fixed tag.
- **Decode the SMMU fault before changing anything.** `FSR=0x402` is a
  translation fault, `0x408` is a **permission fault** (`FSR_PF` is bit 3;
  `FSR_UUT` is bit 8, so UUT would read `0x500`) and `FAR` is the input
  address. `FSYNR0` bits 5/6 mark the fetch privileged and an instruction
  fetch (`0x1c0063` / `0x1e0063` seen here), which tells the privilege level
  the page permissions must allow: with the ICACHE fetch left unprivileged
  (APRIV bit 0 clear, as a660 does) the PTEs must set `AP[1]=0`.
- **The ZAP resets the GPU.** After `zap auth` the CP register block is back
  at the bootloader's values, so the ring and SQE bases have to be published
  again *after* the ZAP, before `CP_SQE_CNTL=1` (redwood's order: ZAP, then CP
  registers). The SMMU context survives the ZAP.
- **PM4 headers**: `CP_THREAD_CONTROL` and `CP_ME_INIT` need real type-7
  headers (`7<<28 | count | parity | opcode<<16`); a `0x80000000` header makes
  the SQE drop the packet.
- **HFI replies carry the sequence in the payload, not the header.** The GMU
  answers with type 1 in `header[19:16]` and echoes the request's sequence in
  the first payload word's `[31:20]`. Matching the sequence in
  `header[31:20]` (the first implementation) discards every response, so every
  HFI command looks like a timeout, the GMU never receives the power tables or
  the OOB/hold command, and the CP start hangs on its first register access.
  With the match fixed the probe reports accepted `hfi perf/bw/vote` and the
  `hold`.
- **The CP runs.** The SMMU loop programmed only two of the four stream slots
  it had reserved, so SID 1 (BV) and 0x401 (LPAC) were unmatched: the SQE
  starts both engines on its first packet, their fetch hit an unmatched
  stream and the CP wedged at `CP_SQE_CNTL=1` with the register port dead.
  With all four SMR/S2CR pairs the CP drains `CP_ME_INIT` (`CP_RB_RPTR` 10),
  authenticates the ZAP and drains `CP_SET_SECURE_MODE(0)` (12).
- **a7xx PM4 headers carry odd parity.** Bit 15 is the parity of the payload
  count, bit 23 the parity of the opcode, bits `[27:24]` are zero (vendor
  `cp_type7_packet`, checked by `pkt_is_type7`). A header with the wrong
  parity is an opcode error: the CP consumes the header, stops at the same
  ucode PC with `rbbm` idle, `CP_INTERRUPT_STATUS` 0 and no SMMU fault, which
  looks exactly like a hang inside the packet. Build every packet through
  `mondrian_pm4_type7`: `CP_MEM_WRITE` (0x3d, count 3) is `0x703d8003`, not
  `0x703d0003`.
- **`CP_THREAD_CONTROL` with `SYNC_THREADS|BOTH` stalls this ring.** The sync
  waits for BV, which is not running until a user submission starts it; the
  CP stops at the packet and never consumes the next one. `SET_SECURE_MODE(0)`
  goes in alone, and `CP_ME_INIT`'s preamble carries `BIT(27)` (concurrent
  binning disabled), not the both-threads bit.
- **Measured end to end**: after the switch a `CP_MEM_WRITE` writes
  `0x600dc0de` into the memptr page and a `CP_EVENT_WRITE` (0x46,
  `CACHE_CLEAN|BIT(27)`) fences `0x600dc0df` into the next dword; `rptr` and
  `wptr` end equal (21), the RPTR shadow follows, `CP_INTERRUPT_STATUS` 0.
- **SMMU context**: pong's qualified image for this chip, `sctlr` 0x127 and a
  write-back inner-shareable walk (`0x3500`); the earlier `0x1027` kept
  ASIDPNE and had fault reporting off.
- **The GPU baseline works with the SQE stopped.** Probe powers CX/GX, boots
  the GMU, sends the HFI power tables and the hold, hardware init reads back
  `rbbm 0x1`, and the ZAP authenticates (`zap init/mem/auth 0/0/0`). With
  `CP_SQE_CNTL=0` the boot reaches SpringBoard and resets cleanly;
  `gpustart=1` runs the whole sequence above.
- **Next**: indirect buffers (`CP_INDIRECT_BUFFER_PFE`), the ring/fence pair
  the user client will submit through, then IRQ 332 and the msm DRM user
  client that Mesa's `msm` KMD talks to. The firmware blocks, the GMU context
  bank and the CM3 start are in `mondrian_gpu.c` under `gmustart=1`.

## Android capture (2026-10-28)

A temporary split (`docs/DUAL_BOOT.md`) booted LineageOS 24.0 userdebug
(`lineage_mondrian-userdebug`, Android 17) on the 5.10.269 GKI kernel, with
the vendor GPU modules `gpucc-waipio.ko`, `gdsc-regulator.ko`,
`qcom_rpmh.ko` and `icc-rpmh.ko`. Measured:

- kgsl `Adreno730v3`, idle 285 MHz, OPPs 220-900 MHz, `gmu_ab 0x0a30`.
- `gpu_cc_gx_gdsc` is supplied by `pm8350c_s2_gfx_voter_level` (PM8350C S2,
  an ARC regulator); `gpu_cc_cx_gdsc` by `pm8350c_s6_level`.
- The GX GDSC syscons are `0x3d99058`, `0x3d99358`, `0x3d9958c` and
  `0x3d99504`; the last is GPUCC offset **`0x9504`**, not `0x99504`. The
  vendor `gdsc-regulator` sequence is: assert/deassert the three sw-resets,
  pulse `GMEM_RESET` (bit 4) in `0x9504`, clear `GMEM_CLAMP_IO` (bit 0)
  there, then clear `SW_COLLAPSE` in `0x905c`. `0x9060` is `CFG_GDSCR`, not
  a clamp register.
- The kernel has no `debugfs` and recovery has no `/dev/mem`, so the GPUCC
  registers cannot be read from Android; the sequence above is the reference.

The first XNU attempt after the capture voted `mx`/`cx`/`mxc`/`gfx` at
`0x1a0` and sent the VRM voltage/enable/mode commands to the ARC resources;
the ARC resources only accept the level at `+0`, so those extra commands are
not valid. The earlier `0x99504` write was outside the GPUCC mapping and
hung the bus. GX remains off; the vendor `gdsc-regulator` order above is the
reference for the next attempt.

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

- **`bootcpu`**: `cpufreq` is in (`0154`: 1804/2496/2995 MHz on the three
  domains); the boot CPU is still 0 (a little core). HackiOS boots with
  `cpus=8 bootcpu=7 cpufreq=1`. The live SM8475 tree has
  `qcom,cpufreq-hw-epss` at **0x17d91000/0x17d92000/0x17d93000**,
  `qcom,lut-row-size=4`; HackiOS's own base is 0x18591000, so only the base and
  the domain table change. The topaz 0094 is the SM6225 variant. Port the
  `bootcpu` half.
- **`IOAcceleratorES`**: topaz's 0138 (an empty `IOAcceleratorES`) saves ~30 s
  at every backboardd start; check what the mondrian's `0114` publishes.
- **Display refresh**: the topaz 0941-0949 add the vsync/presenter, direct
  frames and 60 Hz; today `mondrianfb_hz=60` (the panel itself is 120 Hz).
- **Canvas**: `mondrianfb_canvas_w/h` (default the panel) renders
  CoreAnimation into a smaller surface and scales it to the panel in
  `swap()`; 900x2000 measures 9.3 fps average (1-19) against 6.4 at the
  full panel (1-23), but the CPU scale in `swap()` costs 30-40 ms per swap,
  so the gain is smaller than the pixel count suggests. Use
  `mondrianreset=150`: a 45 s reset cuts the boot before the first swap.
  The CP tests hard-reset a non-journaled HFS; after several resets the next
  mount can take longer than 60 s (the ring stops at the UFS GPT with one
  process), so use 300 s or run `fsck_hfs` on the root image.
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
