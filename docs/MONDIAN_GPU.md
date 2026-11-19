# GPU and boot time

The UI renders through the GPU: the draw completes, the frame is drawn in
place (no readback, no copy), and a burst of frames runs at the panel's 60 Hz
(11-17 ms apart, `glframes=1`). What the user feels is not rasterisation but
whether a finished frame reaches the panel at the tick it was made for: the
compositor commits in bursts on a clock of its own, so the frames are fitted to
the free-running panel with a two-deep queue (see "The cadence" below).
The other ios-sweet ports render through
**Mesa/freedreno OpenGL ES behind CoreAnimation's OpenGL ES renderer**; none of
them has Metal. That is the path this port follows.

## Reference stack

- **ios-topaz** (`MakrSas/ios-topaz`, a port of ios-sweet to SM6225, iPhone X
  iOS 16.7.16): kernel `RedwoodGPU` (an msm-style GPU client), `SweetSurface`
  IOSurface + `IOMobileFramebuffer`/`AppleCLCD` over the MDP; userland
  `userland/gpu` (`eagl.c`, `gl_osmesa.c`, `inject.c`, `bbd_wrap.c`) and
  `userland/mesa` (freedreno Darwin patches, `redwood-drm`). Patches
  `0900`-`0950`. Credits HackiOS (APSL 2.0 kernel, MIT user space).
- **HakiOS** (`oosexgang/hakios-xnu-kernel`, v2.3.4, Darwin 22.5 on sc7280 /
  SM7325, a6xx): Adreno through Mesa GLES, `gpu=1`. Its ring code is the
  reference for ours: `ring_at = (ring_at + 1) % RING_WORDS` and
  `CP_RB_WPTR = ring_at`, i.e. the write pointer is never published at or past
  the end of the buffer, and a lap is closed by writing one `CP_NOP` over the
  tail (kgsl `adreno_ringbuffer_allocspace` does the same). Its `CP_RB_CNTL`
  adds bit 27, "do not copy the read position to memory", so it reads
  `CP_RB_RPTR` from the register and nothing else; kgsl's a7xx default is our
  `12 | 2 << 8`.
- **HakiOS's frame budget** (its `CHANGELOG.md`, 2.3.3-2.3.4) says where the
  time goes on a home screen, and it is not the rasteriser's arithmetic: with
  the wallpaper composed every frame the home button runs at 28 fps, with it
  hidden at 78, and with it frozen as one still picture at 92. The wallpaper is
  `PosterBoard`'s layers through a layer host, and its gradients were drawn
  3509 times a run at 0.6 ms each. The second lever is the screen class: it
  renders 828x1792 (XR) or 750x1624 (X) at 2x and stretches to the panel,
  `fbsubtype`/`fbwidth`/`fbheight`/`fbscale` choosing the class, which is 1.85x
  fewer pixels for the GPU. Both are cheap for us and neither is in the kernel.
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
- Display: `mondrianfb` writes the panel and kicks its command-mode DSI
  interface at 60 Hz; the DPU scans the ABL's splash carve-out. The GPU path
  needs the IOSurface/`IOMobileFramebuffer` presentation (topaz's
  `SweetSurface`), with the iPhone X 1125x2436 canvas on the 1440x3200 panel.
  The panel is **120 Hz**, but the iPhone X userland and CoreAnimation run at
  60 (no ProMotion): 60 is the first target, 120 only by forcing the display
  link/ProMotion.
- CoreAnimation: the `eagl`/`gl_osmesa`/`inject` userland, the Mesa `FD730` and
  the AMFI/dyld policy that lets the Mesa GLES context load
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
  header is a local input, not committed; without it `mondrian_gpu.c` does not
  compile (`docs/BUILD_LINUX.md` has a public source for the blob). The CP
  path below also needs a local `mondrian_cp_profile.h`; without it `0184`
  leaves the user client inert.
- **HFI power and GX**: the GMU ACKs PERF (id 4, 58 words), BW (id 3, 159),
  CORE_FW_START (14), the default vote (30, `gpu 2 bus 2`) and START10 with
  `err 0`; `oob_gpu` is held and GX reads `PWR_ON=1` (`gdscr 0xf8222800`,
  `gx hw 0x0`). `GEN7_GMU_GFX_PWR_CLK_STATUS` reads 0x0 (GX power and clock
  on) and the `gpu_cc_gx_gfx3d` branch 0x221 after START10.
  The tables come from the live cmd-db (`gfx/mx/cx`,
  SH0/MC0/ACV) and the 13 mondrian OPPs, the same data as Pong's
  `PongAdrenoPower.c`. A full boot with the tables and GX on reaches
  SpringBoard and the touch report thread.
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
- **The SMMU latches its last fault and never clears it.** A dump built from
  `FSR`/`CB_FAR` proves nothing on its own: the identical
  `fsr 0x80000402 far 0x13e0d080` appears after a stream that completes in
  11 ms and after the draw that wedges, because both inherit what bring-up left
  behind. Clear `FSR` and `GFSR` (write `0xffffffff` to `ctx+0x58` and `0x48`)
  before the doorbell, and read them after: only then does a non-zero syndrome
  belong to the submission being measured. `0200` does this behind `gpudump=1`
  and resolves `CB_FAR` through the CP's own tables (`gpudump` prints
  `pte present|absent`), which separates a stale TLB entry from a buffer the
  client never mapped.
- **The SMMU is not what drops the render path's writes.** The tables are
  installed for SID `0x5` and `0x405` (`smr 0x80000005` / `0x80000405`) and the
  log shows `s2cr 0x1` for both, which is `S2CR.TYPE = TRANS` (type is bits
  `17:16`; BYPASS is `1 << 16`, FAULT is `2 << 16`). SID `0` — the lease
  Pong's `smid` uses — matches no SMR and therefore falls back to `S2CR[0]`,
  the same translate entry, so the context bank, its `TTBR0` and its `MAIR0`
  cover every stream ID the GPU can raise. `0x20000` in the other slots is
  FAULT, i.e. those slots are unused, not bypassed. A missing render SID would
  have to be matched *and* pointed at a second bank to explain a silent drop,
  and nothing writes a second bank.
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
- **The switch is what puts the render blocks in nonsecure mode, and the
  whole GPU write path depends on it.** The bootloader leaves
  `RBBM_SECVID_TRUST_CNTL=1` (trusted) and a non-secure write to it aborts, so
  the register route mainline takes without a zap shader is closed here;
  `CP_SET_SECURE_MODE(0)` is the only way out. With the switch retired
  (`cp secmode rptr 12 wptr 12`) the 2D probe writes: `2d fill … nonzero
  64/64 first 0xffffffff` and the 8 MiB blow scans `nz 2097152` at
  `0xffffffff`. With it skipped (`cpnosecmode=1`) the same submission writes
  nothing, the scan finds only the CP's own canary, and the UCHE trap page
  stays zero. That is the entire "no write and no fault" signature: a trusted
  GPU sends the render blocks' traffic down the secure path, whose TSB this
  port leaves empty (`RBBM_SECVID_TSB_CNTL` 0), so it is dropped silently,
  while the CP's privileged traffic keeps translating and its fence lands.
  A `CP_MEM_WRITE` canary is therefore not evidence that the render path
  works — it is a privileged access and takes the other route.
- **The switch parks on some boots.** `cp secmode rptr 11 wptr 12`, SQE at
  ucode PC 0x649, `fault 0`, `int 0x80`: nothing behind it runs. The retry
  puts a `CP_NOP` over the stalled dword and re-sends the switch
  (`cp secmode retry rptr 11 of 15`), after which the CP continues; a boot
  that reaches `rptr 12 wptr 12` is the one to judge.
- **`CP_APRIV_CNTL` is what decides whether a privileged packet is refused.**
  The SQE microcode reads `CP_APRIV_CNTL` (0x844) and mirrors it into its
  per-pipe privileged-opcode mask (internal `0x0aa`), so with that register
  unprogrammed a privileged packet is rejected with `CP_INTERRUPT_STATUS` bit
  7 (`CP_ILLEGAL_INSTR_ERROR`) while `CP_HW_FAULT` stays 0. Vendor
  `gen7_start` and mainline set `0x4f`, `CP_BV_APRIV_CNTL` `0x0f`,
  `CP_LPAC_APRIV_CNTL` `0x0f` and `CP_LPAC_PROTECT_CNTL` `0x0b` before the
  ring/SQE bases; the ZAP resets the block, so they have to be written again
  after it and before `CP_ME_INIT`, which therefore has to be re-published
  (`cp meinit rptr 10 of 10`). `cpapriv=0` restores the old path. APRIV alone
  does not make every privileged packet legal: with it programmed and the CP
  nonsecure, `CP_EVENT_WRITE` with event `0x31` (`CACHE_CLEAN`) is still
  refused, so the event type matters on its own.
- **The protected-mode bracket is not a substitute, and not in the frame.**
  On a7xx neither kgsl ("all submissions run with protected mode off due to
  APRIV") nor mainline emits `CP_SET_PROTECTED_MODE` per submission, and
  ending a bracket with `(1)` leaves protection *on* for whatever follows;
  payload 0 leaves protected mode, 1 enters it. With `cpapriv` on, a frame
  carries no `0x5f` and the first submission prints `uc frame no
  protected-mode packet`; `cpprot` then only reaches a `cpapriv=0` boot, which
  restores both halves.
- **`cp notready secure 0x%x apriv 0x%x cp2gmu 0x%x tsb 0x%x/0x%x`** follows a
  failed bring-up: `CP_SECURE_MODE`, the APRIV read-back, the CP's GMU status
  and the secure TSB status pair. A non-zero `tsb` means the secure fetch does
  not validate, `apriv` back at 0 means the block was reset again after the
  re-arm, and a non-zero `secure` means the switch really did not happen.
- **`gpureset=1` (GMU HFI power off/on) is not a usable reset.** Both acks
  return 1 and the CP does go back to `rptr 0`, but it then stops on
  `CP_ME_INIT` itself (`cp meinit stuck rptr 0 of 10`, header `0x70c80007`,
  ucode PC 0x10e): coming back from a collapse needs the vendor's power-up
  sequence, not just a republished ring and SQE base.
- **`cp notready detail`** prints what separates a hang from a fault: SQE
  status pops 2-3, `trust`, `sqebase`, `rptr`/`wptr`, `sqecntl`, `hw fault`,
  `CP_INTERRUPT_STATUS`, `RBBM_STATUS3` and CPU copies of ring dwords 8-13.
  `fault 0`, `rbbm3 0` and `int 0x80` on a stalled packet mean no bus or
  fetch error: the microcode is waiting, not lost.
- **SMMU context**: pong's qualified image for this chip, `sctlr` 0x127 and a
  write-back inner-shareable walk (`0x3500`); the earlier `0x1027` kept
  ASIDPNE and had fault reporting off, which is why the faults below were
  invisible.
- **Packets from an indirect buffer run unprivileged.** A `CP_MEM_WRITE` in
  the ring reaches a `AP[1]=0` (privileged-only) page; the same packet inside
  an IB faults with `FSR 0x408` at the destination. Every buffer a submission
  touches therefore needs `AP[1]=1` (user accessible), which is pong's
  `perms 3` for the ring, memptr, power-up list and scratch, and the vendor's
  `IOMMU_READ`-without-`IOMMU_PRIV` for user buffers. The SQE stays `perms 5`.
- **The ring is closed with a `CP_NOP` when it wraps, and nothing else is
  published.** The CP fetches from the read pointer towards the write pointer,
  so a write pointer that jumps back to zero leaves it fetching dwords nobody
  wrote (the ring starts zeroed, so they decode as type-0 register writes).
  One `CP_NOP` covers the tail and the cursor restarts at 0; the only value
  ever written to `CP_RB_WPTR` is the small one that comes with the next
  submission. Publishing the one-past-the-end value instead makes the CP fetch
  the tail and then never fetch lap 2 (measured at 32 KiB and 128 KiB, see
  `0266` below). Measured with 2000 back-to-back submissions: 183 refused
  before the fix, 0 after it, with the last canary and fence exactly the ones
  the last submission asked for.
- **A clean publishes what was written, in the page's own offset.** With 16 KiB
  pages (`__ARM_16K_PG__`) the offset inside a physical page is the low 14 bits;
  a clean that masked it with 0xfff cleans the first 4 KiB of a page for every
  quarter of it. Measured (`0222`): the CP stopped dead at ring dword 0x400, the
  first dword of the second quarter, and `uc room poll` spun on `rptr 0x403 room
  18` for the rest of the boot while a thousand submissions piled up behind it.
  The rptr read after the wrap looked a kilobyte ahead of the writer, so the ring
  only "filled" a lap later. `0225` restores 0x3fff; a boot that stops consuming
  with `rptr` frozen just past a 4 KiB boundary is a clean, not the CP.
- **Back-to-back submissions work.** Two `mondrian_gpu_uc_submit` calls in a
  row (the exact call the user client makes) return fences 1 and 2, both
  waits complete, both canaries and both fence dwords land: ring advance,
  fence slots and the publish/wait pair are in order, which is what Mesa's
  msm backend produces.
- **Indirect buffers work.** `CP_INDIRECT_BUFFER_PFE` (0x3f, payload addr
  lo/hi and the size in dwords) pointing at a 9-dword IB runs the whole
  stream: the canary and the fence inside it land, `rptr` reaches `wptr`, no
  interrupt. That is the submission shape Mesa uses.
- **The GPU is on by default.** `tools/boards.py` passes
  `gpu=1 gpupower=1 gmustart=1 gpugx=1 gpucp=1 gpusubmit=1`; the probe powers
  CX/GX, boots the GMU, sends the HFI power tables and the hold, hardware init
  reads back `rbbm 0x1`, authenticates the ZAP, starts the CP, proves an
  indirect buffer and publishes `MondrianGPU`. The boot still reaches
  SpringBoard, so the two do not compete. `gpustart=0` stops the SQE and
  `gpu=0` skips the block, which is what to boot if the GPU path is being
  changed and the rest of the port has to stay usable.
- **The user client is `MondrianGPU`** (`0182`, `iokit/Kernel/arm`). Mesa's
  freedreno speaks Linux msm DRM, not IOAccelerator: `IOServiceOpen` on
  `MondrianGPU` and then one `IOConnectCallStructMethod` per request, with
  the selector equal to the low byte of the ioctl code and Linux's
  `msm_drm.h` structures unchanged (GET_PARAM 0x40, GEM_NEW 0x42, GEM_INFO
  0x43, CPU_PREP/FINI 0x44/0x45, GEM_SUBMIT 0x46, WAIT_FENCE 0x47, GEM_CLOSE
  0x09). A buffer is mapped in user space by its handle
  (`clientMemoryForType`), so the Darwin libdrm stands in for `mmap`.
  Relocations are refused; Mesa's msm backend uses softpin (`MSM_INFO_SET_IOVA`
  and `GET_IOVA`), which works. GEM_NEW also refuses (`MondrianGPU: gem_new
  <size> refused`) when the descriptor or the IOVA comes up short; Mesa's
  callers then answer `GL_OUT_OF_MEMORY` (0x505) or crash in Mesa's
  first-context self test. The low 4 GiB is what runs out first while the
  window server runs; `0211` allocates above it when the low pool is spent.
  GEM_SUBMIT carries one BO per buffer the frame touches — 95 on a lock-screen
  frame — and `0219` raised the old 64-entry limit that refused them whole
  (`submit failed: -22` from Mesa's `flush_submit_list`, 220 times a boot).
- **Fences are CP-written dwords**: a submission is `CP_INDIRECT_BUFFER_PFE`
  plus `CP_EVENT_WRITE` into a slot of the memptr page, waited on through the
  write-combined alias of that page. No IRQ is needed for correctness; IRQ 332
  is only needed for the timestamp path Mesa uses on real hardware.
- **Buffers are coherent by construction**: the user mapping is handed out
  with `kIOMapInhibitCache` (the GPU reads and writes DRAM directly), and the
  user client write-backs the command stream with `flush_dcache64` before the
  ring publishes it. A cached user mapping shows the CPU's own writes back to
  itself and hides the GPU's.
- **The whole path works from user space, measured.** `tools/mondrian-gpu-test.c`
  waits for `MondrianGPU`, reads the chip id, allocates and maps a buffer,
  submits a `CP_MEM_WRITE` canary plus a fence through `GEM_SUBMIT`, waits on
  `WAIT_FENCE` and reads both values back through the mapping. It passes in
  every process the UI hook is injected into (containermanagerd,
  backboardd, SpringBoard): chip `0x07030002`, buffers at successive
  `0x10000000`/`0x10010000`/`0x10020000` (one arena per connection), fences
  continuing from the kernel's own submissions, and the canary and fence
  exactly the values the stream wrote. Build with
  `tools/build-mondrian-gpu-test.sh`; it is dlopened by
  `mondrian-ui-hook.dylib`.
- **What user space still cannot do**: import an IOSurface (`0x7e` is
  implemented and compiled but has no caller until the CoreAnimation hooks
  are wired), relocations (Mesa uses softpin), and prime/syncobj file
  descriptors (stubs that return `ENOSYS`).
- **Mesa runs on the GPU and submits; the CP refuses some packet types.**
  OSMesa over freedreno's msm backend reports `vendor freedreno`,
  `renderer FD725`, Mesa 25.0.7, and submits through `MondrianGPU` with
  softpin (no relocations). Its first stream (222 dwords: `CP_SET_MODE`,
  `CP_THREAD_CONTROL`, CCU invalidates, `CP_INDIRECT_BUFFER`, type-4 register
  writes, `CP_SET_AMBLE`, a `CACHE_FLUSH_TS` fence) **completes**, and so does
  every prefix of it up to 34 dwords. `CP_BLIT` is the packet this CP answers
  with an opcode error (`CP_INTERRUPT_STATUS` bit 0, `CP_HW_FAULT` 0, SMMU FSR
  clean, `CP_IB1/IB2_REM_SIZE` 0 because the fetch already finished): replacing
  every `CP_BLIT` with a `CP_NOP` (`gpunoblit=1`) makes all of Mesa's
  submissions complete. `FD_MESA_DEBUG=noblit` (the generic blit path) still
  fails, so the draw path is refused too, which points at the packet set the
  SQE firmware accepts rather than at one packet.
- **The SQE was halting on an unknown opcode, and the cause was cache, not
  packets.** `CP_SQE_STAT` reads `pc 0x224`, which `afuc-disasm` identifies as
  the microcode's halt loop (`l548`); the error table above it writes 1 (or 2)
  to control register 0x064 before jumping there. The dword it rejected was
  zero: a `CP_SET_DRAW_STATE` fragment, a VBO or a const buffer that Mesa had
  filled through the CPU but that had not reached DRAM. The driver only wrote
  back the command buffers, so whether the CP saw the fragment depended on
  cache eviction — the same stream completed in one boot and halted in the
  next. Writing back every buffer of the submission, the way
  `msm_gem_submit` does (`getPhysicalSegment` + `flush_dcache64` per page),
  fixes it: `MONDRIAN MESA TEST: PASSED`, pixel `255 0 0 255`.
- **The microcode refuses `CP_SET_DRAW_STATE` while `$14[29]` is set, and
  `CP_SET_MODE(0)` sets it.** `CP_SET_MODE(1)` clears it (unless the SQE is
  inside its draw-state setup); with MODE 0 the packet takes the error-2 path
  to the same halt loop, and the draw handler also skips applying groups. That
  is why an earlier `gpunop=0x43` looked like a fix: it removed the packet. Not
  needed once the buffers are coherent; `gpumode=1` stays as a bisect knob.
- **Mesa's a6xx binning packet parks the a730 SQE.** The first frame with a real
  draw set stopped the CP 704 dwords into 1785 with `uc sqe pc 0x604 packet
  0x702f0007 ib1 ... rem 0x439`. `0x702f0007` is `CP_SET_BIN_DATA5` with seven
  payload dwords, the a6xx layout, which `fd6_gmem.cc:1279`
  (`OUT_PKT7(ring, CP_SET_BIN_DATA5, 7)`) emits on a7xx too; Turnip writes
  `CP_SET_PSEUDO_REG` plus the `_OFFSET` variant instead
  (`tu_cmd_buffer.cc:1095`; in `adreno_pm4.xml` a7xx appends two more addresses
  and dword 0 grows a `VSC_MASK`). The a730 firmware initialises the length of
  its memory read (`$09` = `MEM_READ_DWORDS`) only in the ≥8-dword path
  (`sqe-a730.asm:1765`; vendor blob 01730158 and upstream 01730181 are identical
  here), so seven dwords leave the read empty, `$memdata` reads 0, and the
  handler parks in `l1539: jump #l1539` (pc 0x603/0x604). That park is silent:
  `CP_SQE_STAT` names the packet, while `CP_INTERRUPT_STATUS` stays 0 and
  `CP_HW_FAULT` 0 — unlike the error halts `l546`/`l548`, which write `0x064` and
  raise the interrupt. No fence follows, so `0191` marks the GPU stopped and
  refuses every later submission, and CoreAnimation falls back to softpipe.
  `glenv=FD_MESA_DEBUG=nobin` removes the packet: `use_hw_binning()`
  (`fd6_gmem.cc:370`) returns false and the tile stream takes the
  `CP_SET_VISIBILITY_OVERRIDE(1)` path that the 71- and 168-dword streams already
  exercised. Binning has nothing to buy here (the compositor renders off-screen),
  and the argument is in `tools/boards.py`.
- **Nothing on this board is IO-coherent, and XNU's cache helpers are a barrier
  here.** `__ARM_COHERENT_IO__` is defined for arm64
  (`pexpert/pexpert/arm64/apple_arm64_common.h:36`), so `flush_dcache()` and
  `clean_dcache()` compile to a bare `dsb sy` (`osfmk/arm/caches.c:383`). Every
  flush this port ever asked for was therefore a barrier and not a clean:
  `0222`'s command-stream writeback, its ring range clean, and `0225`'s page
  offset fix on top of that clean. `mondrian_gpu_uc_flush()` does the work
  itself now — `dc civac` a line at a time, the line size from `CTR_EL0`,
  through the physmap alias of the page, then `dsb sy`. ios-topaz found the
  same thing and said it plainly (`0111` there: "this kernel is built with the
  Apple SoC config (`__ARM_COHERENT_IO__`), where clean_dcache/flush_dcache are
  no-ops").
- **A surface is mapped with two cache attributes, which is a hazard of its
  own.** The display's copy reads through `MondrianSurface::kernelAddress()`, a
  `kIOMapWriteCombineCache` (Normal Non-Cacheable) view, while the process that
  draws holds a `kIOMapDefaultCache` (cacheable) view of the same pages
  (`MondrianSurface.cpp:733`). ios-flame names it: "any WC/NC view of a managed
  page is a mismatched alias: CPU writes through it got lost / reads went
  stale". What works is to clean and invalidate by physical address before the
  copy — `MONDRIAN FB: probe N layer a id s ...` says what the surface held and
  `panel ...` what the copy left (`mondrianfb_probe=N`), and
  `mondrianfb_nocoh=1` turns the clean off for the A/B.
- **`glblob=1` lands one boot late.** The kernel writes
  `/private/var/vm/mondrian-gl.dylib` once the root is remounted writable, and
  `backboardd` has loaded the dylib by then, so a userland change is in place on
  the *next* boot, not the one it was built for. The ring shows
  `MONDRIAN GLBLOB: <path> <bytes> -> 0` after the hook's lines; `-> 30` (EROFS)
  means the volume is read-only and the copy in the root is what runs.
- **The GPU's pixels never reach memory, and `CP_EVENT_WRITE` is why.** A self
  test at the first GL context clears a texture of the renderer's own to red and
  reads it back (`mondrian-gl: gpu self test: fbo status 0x8cd5, clear+read 00 00
  00 00, error 0x0` in every boot measured): the framebuffer is complete, there
  is no GL error, and the readback is zeros. That is not CoreAnimation's state —
  it is the GPU's output. freedreno drives the RB blit engine, which is both the
  *clear* and the GMEM→memory *resolve*, with `CP_EVENT_WRITE(FD_BLIT)`
  (`fd6_emit.h:308`, event 30 = `0x1e`), and cleans its caches with
  `FD_CACHE_CLEAN` (`0x31`); this CP refuses event writes with
  `CP_INTERRUPT_STATUS` bit 7, which is the same refusal that forced the ring
  fence to be a `CP_MEM_WRITE` (`cpfence=mem`, `0196`). `cpapriv=0 cpprot=1`
  does not change it.
- **On a7xx that packet is `CP_EVENT_WRITE7`, and its write is off unless
  `WRITE_ENABLED` is set.** `adreno_pm4.xml` gives the a7xx form dword 0 as
  `EVENT[7:0]`, `WRITE_SRC[22:20]`, `WRITE_DST` (24), `WRITE_ENABLED` (27) and
  `IRQ` (31), with the address in dwords 1-2 and the payload in dwords 3-4 —
  "writes into `WRITE_DST` from `WRITE_SRC`; `RB_DONE_TS` requires
  `WRITE_ENABLED`". Mesa's GL path emits the a6xx shape, without the bit, so on
  this CP an event write is a no-op that also reads as an illegal packet. The
  port's own fence has always set it (`0x31|BIT(27)`, and `cpevent=4` sends
  `08000004`), and Mesa does the same for its timestamp — that is why the fence
  and the timestamp work and the clear does not. `0228` rewrites every event
  write in a submission to that shape (`gpuevent=` limits it to event numbers,
  `gpuevent=0` turns it off), and the write does then happen — but the first
  stream that carries one parks the CP: measured `uc big 253 dwords fence 1 done
  0`, `uc sqe pc 0x2f8 packet 0x70460001 ib1 ... rem 0x0` (the whole IB
  consumed), `int 0`, `fault 0`. So the bit alone is not the form this firmware
  takes: the next thing to try is the full a7xx payload (`WRITE_SRC`/
  `WRITE_DST` set as Mesa's timestamp packet does, five dwords), and the
  self test is opt-in (`glselftest=1`) so its own stream is not in front of
  CoreAnimation's while that is bisected.
- **Neither a730 firmware has a BLIT event; `CP_BLIT` drives the 2D engine.**
  The SQE's `CP_EVENT_WRITE7` handler (`sqe-a730.asm:810`, identical in the
  vendor 01730158 and upstream 01730181 blobs) compares the event number
  against `0x31, 0x32, 0x16, 0x20, 0x21, 0x1a, 0x15, 0x9, 0x11-0x14` and
  nothing else: `BLIT` (30 = `0x1e`), which is what both freedreno and Turnip
  use to trigger the RB blit engine, falls through to the generic path and is
  not dispatched. `CP_BLIT` (`0x2c`, `sqe-a730.asm:2469`) *is* implemented and
  is what starts the engine (`EVENT_CMD = 4`, then `HLSQ_EVENT_CMD`/
  `PC_EVENT_CMD` with `0x2a`/`0x2b` and `CP_EVENT_END`), with the a5xx blitter
  (`a5xx/fd5_blitter.c:273`) as the shape that builds it: `CP_BLIT` with
  `BLIT_OP_FILL`/`COPY` and the source and destination rectangles, followed by
  `CP_SET_RENDER_MODE(END2D)`. So the a7xx GL path's clears and resolves cannot
  work on this chip as Mesa 25.0.7 emits them, and the candidates are a Mesa
  patch that drives `CP_BLIT` on a7xx (the RB blit registers the same code sets
  up are what the engine reads) or a driver-side rewrite of the `FD_BLIT` event
  into that packet.
- **The `BIT(27)` rewrite desynchronises the stream; count-1 events are legal.**
  The a730 handler for `0x46` (`sqe-a730.asm:810`, opcode `0x46` dispatch at
  `0x1a64` in the vendor build) takes an explicit no-write path when
  `WRITE_ENABLED` is clear: `brne $0a, b27, #...` and it reads *zero* dwords past
  the event word. With the bit set it always consumes the 64-bit address and
  then a payload dword chosen by `WRITE_SRC`, with no `$rem` guard — so on a
  count-1 packet it eats the following headers, the rest of the IB runs as
  garbage and nothing is written. That is the measured stall: `pc 0x2f8` is not
  an event handler but `CP_WAIT_REG_MEM`'s sixth payload read
  (`0x2e4`-`0x3ac`, `0x2f8` = `ubfx $04, $data, b0, b16`) with `rem 0x0`, i.e.
  the SQE waiting for a word that never comes, `int 0` and `fault 0`. The legal
  shapes are the ones Mesa already emits (`fd6_emit.h`): event + `WRITE_ENABLED`
  clear and count 1 for a pure flush/invalidate/resolve; count 4
  (`EV_WRITE_USER_32B` + `EV_DST_RAM`) with the bit for a fence; count 2 for the
  on-chip timestamp sum. The vendor driver for this exact phone emits the
  count-1 form in every submission (`adreno_gen7_ringbuffer.c`:
  `cp_type7_packet(CP_EVENT_WRITE, 1)` + `0x31`, and `24`/`25` for the CCU
  invalidates), so the count-1 packet was never the problem; `0228`'s rewrite is
  off by default and is only a bisect tool.
- **Every GPU-side memory write reads black; the CP's do not.** The self test
  covers the three pieces in order — the clear (RB blit → CCU → memory), a
  CPU-to-GPU texel upload read back through the GPU (a `CP_LOAD_STATE6` state
  load, the same packet class the shaders travel in) and a shader draw — and
  all three read back zeros, with the FBO complete and no GL error, on the no-
  binning and the sysmem and the UBWC-off configurations — while the CP's own
  writes land (the canary, the fence and Mesa's buffers are written by the CP
  and read back correctly). So the failure is not one engine or one packet:
  it is the render path's memory writes as a whole
  (`UCHE → GBIF → SMMU → DRAM`), where the CP's are fine. Right next to it:
  the two buffers carry the same permissions the CP writes with (`perms 3`,
  `AP[2]=0`), the bootstrap's `THREAD_SYNC` handshake at `l162` is passed,
  every submission fences, and GL on this chip works elsewhere with the same
  Mesa.
- **The pipeline matrix is measured, and every cell is black.** The self test
  ran on the default (GMEM, `A7XX_RB_UNKNOWN_8812(0x3ff)` "all buffers in
  sysmem"), with `glenv=FD_MESA_DEBUG=sysmem`, with `gmem` forced and with
  UBWC off, and with `glcopy=1`; the clear, the texel upload and the draw read
  zeros in all of them, with the FBO complete, no GL error and every submission
  fencing. `glcopy=0` then draws CoreAnimation's layer *in place*
  (`1 drawn in place` in the frame line, fps 3, frames 11 ms late instead of
  4.7 s), and the kernel's probe of that surface — a write-combining mapping,
  so no stale cache — reads `first 0x00000000`, alpha included, while the copy
  path had left `0xff000000` there. So the surface the panel scans is never
  written, and that is upstream of both the readback and the presentation; the
  cause is the trusted GPU without `CP_SET_SECURE_MODE(0)`, not the RB or the
  address. **The RB can write memory, though:** `0231`
  puts a `RB_DONE_TS` (event 22, `WRITE_ENABLED`) in an IB and reads the
  address back — `rb done ts 0x0000000000184541 fence 0x600dc0e1 polls 0 int 0
  fault 0`, on the first poll, so the engine that draws writes a 64-bit
  timestamp into DRAM with no fault and the CP's own writes land in the same
  boot (`cp memwrite ... canary 0x600dc0de`, `uc ... done 1 in 0 ms`). What is
  left is *where* a draw writes, and `0232` reads that from the GPU itself:
  after a stream's fence is answered it prints `RB_MRT_0_BASE`, `BUF_INFO`,
  `PITCH` and `RB_RENDER_CNTL`, and `surfaceBuffer()` records the iova it gave
  the IOSurface. Measured: with the boot's own self test in front, the RB still
  had the test's 64x64 texture as its target (`pitch 256`) while the window
  server's frames were being drawn; with `glselftest=0` it moves to the window
  server's own buffer (`0x12251000`, `pitch 5888` = 1472 px) and never to the
  surface (`0x10c24000`, `bpr 5760`). `FD_MESA_DEBUG=sysmem` changes neither
  the target nor the outcome. So CoreAnimation draws into a texture of its own
  and the surface is written only by the present, which is a blit on every
  path: with `glcopy=0` eagl blits the frame into `image->mirror` (the
  surface's memory) with `glBlitFramebuffer`, and with `glcopy=1` it reads the
  frame back with `glReadPixels` first. Measured with `glcopy=1`: `1 picture
  copied out`, 5-11 ms a frame spent copying, and the surface still
  `first 0x00000000`. The fast blit is the 2D engine (`fd6_blitter.cc`'s
  `emit_blit_texture` writes `GRAS_2D_*` and `CP_BLIT`), which
  `FD_MESA_DEBUG=noblit` replaces with the generic 3D blitter. `glmark=1`
  draws magenta into whatever is bound just before the frame is handed on, and
  the probe reads it. The probe itself looked at four pixels of the first 64
  rows, where a black corner and an empty surface look alike; `0234` samples a
  grid over the whole surface and prints `nonzero N/M`.
- **Nothing writes the surface, not even a clear.** `0235` fills a freshly
  adopted surface with `0xffffffff` and marks the buffer dirty, so the pattern
  reaches DRAM before the first submission that names it. Measured: every layer
  reads `first 0xffffffff ... nonzero 4500/4500` and the panel probe reads
  `first 0xffffffff` too, so the pattern survives whole frames and the copy to
  the panel is working — the GPU simply never writes those pages. A draw that
  ran and a surface that was never touched are then distinguishable in one
  boot, which is what `gpusurfpat=1` is for.
- **A6xx register offsets park the a730's CP.** The first kernel-side 2D fill
  (`gpu2dfill`, `0236`) re-derived the blit registers from `a6xx.xml` and wrote
  `SP_2D_DST_FORMAT` at `0xacc0`; that is the a6xx offset and the a730 has the
  register at `0xa9bf` (`<reg32 offset="0xa9bf" ... variants="A7XX-">`). The
  next frame took 1.6 s, Mesa logged `flush_submit_list:135: submit failed:
  -35`, and every submission after that failed; the surface then read
  `0xff000000` everywhere, which is userland's fallback and **not** a GPU
  colour write. The fix is to replay the dwords Mesa itself emits — the window
  server's first frame carries a 51-dword clearing IB — and change only the
  destination and the colour. Do the same for any other a7xx register: check
  the `variants` attribute before using an `A6XX_*` constant.
- **The 2D engine is configured and still writes nothing.** `0239` makes the
  replay faithful (Mesa's `RB_CCU_CNTL2` head, measured as `4088e501
  80000000`: colour cache full at offset `0x100000`), then reads the engine's
  state back after the fence and puts a `CP_MEM_WRITE` into the same client
  buffer. Measured: `dst_info 0x3 dst 0x0000000014ae4000 pitch 0x40 blit
  0x10f00380 protect 0x0 fault 0x0`, the canary reads back `cafe1234`, the
  blit's 64 sampled dwords are still zero, and FSR shows no fault. So the CP
  applied every register write, the destination is the buffer, and the GPU can
  write that memory from the CP — the colour is lost inside the RB/CCU, after
  the point where the CP can see it. This also rules out `CP_PROTECT` and
  protected mode for the draws: a refused type-4 write leaves the register at
  its old value, and these read back as written. (Register reads are only
  valid once the fence has answered; a wedged CP stops answering the register
  port and the read never returns.)
- **The blit issues no memory transaction at all.** `0240` points the same
  blit at a page it has just unmapped and cleared FSR/GFSR first. Measured:
  `2d fault ... submit 1 poll 1 fence 10 canary got 0xcafe1234 fsr 0x400
  gfsr 0x0`, where the canary still arrives on the mapped page, so the CP ran
  the IB. A write into an unmapped page raises a translation fault if the
  engine issues it; none appears, so no fragment is produced, or the pixels go
  no further than a cache. `gfx pwr clk 0x0` (the GMU's GX GDSC + GX clock
  status) and `replay ... protect 0x0` together say it is not power, clock or
  a refused register write. Note that a write which sits in the CCU would also
  fault only when it is evicted, so "no fault" alone does not yet separate
  "never drawn" from "never cleaned"; `gpu2dbig=1` (`0241`) blits 8 MiB, more
  than the colour cache can hold, and reads the first rows, which a cache that
  spills must have written back.
- **The SP warm-up kernel belongs in Mesa's stream.** Turnip's
  `tu_init_cmdbuf_start_a725_quirk` (a compute kernel over the whole shader
  array, 12 groups of 255 waves, the register writes that aim it, and
  `CP_EXEC_CS`; "It is unknown what this workaround is for and what it fixes")
  runs at the start of every command buffer on a725/a730 silicon, and Mesa
  25.0.7's GL build did not have it. Two facts from the kernel-side trial
  (`0229`): any nonzero `cpuirk` prefixes one nested IB before the client IB in
  the same ring submission — it is not a separate submission — and that IB
  pointed at the allocation base, which holds the shader, while the PM4 stream
  starts at `+64`, so the CP fetched shader words as packets. `0230` fixes the
  address; the parked CP it produced (`uc big 253 dwords fence 1 done 0`,
  submissions refused) therefore says nothing about the compute kernel itself.
  What follows a wedge is not GPU evidence either: the green self-test lines
  are the restarted process on softpipe. The supported form is emit-side —
  `fd6_emit_restore` builds the stream once per context and emits it when
  `info->a7xx.cmdbuf_start_a725_quirk` is set (a7xx gen1/gen2 in
  `freedreno_devices.py`), with `cpuirk=0` — which is implemented in
  `tools/mesa/mondrian-darwin.patch` and needs a `glblob=1` boot to be measured.
  The bootstrap handshake is not the gap: `l162` in the SQE (`brne $02, 0x0, #l162`, right after
  `THREAD_SYNC` bit 0 is cleared) is the wait Pong describes, and this port
  passes it — the streams execute. `CP_ME_INIT` already carries kgsl's DMS bit
  (`0x14b | BIT(11)`) and the four stream slots are leased in one bank. What is
  left to prove, in this order:
  1. **The render path's SMMU ownership.** The CP writes with bank 0's context
     (SID 0/0x400) and those writes land; the shader/blit engines ride the same
     `_emit` context, so compare the *stream attachments* against pong's lease
     (SID 0/0x400 for user, 1/0x401 for LPAC, one context) and against what the
     SMMU's ACTLR `0x32b` expects — a mismatched route would drop writes with
     no fault on the CP.
  2. **The render blocks' own state** — the one thing kgsl programs that this
     port may not: dump `RB_CCU_CNTL`, `RB_DBG_ECO_CNTL`, `RB_UNKNOWN_8812`,
     `UCHE_CLIENT_PF` as Mesa sends them, then compare against the vendor's
     gen7 startup (NothingOSS sm8475, the matching `gen7_perfcounter`/restore
     list). If the CCU's client Enumeration is wrong, the blit and the
     shader's writes both stay in cache that is never published.
  3. The proven path for a fluid UI on this exact silicon is Turnip
     (`pong-adreno`, Nothing Phone 2, "desktop rendering"), which for a
     CoreAnimation GLES client means GL on top of it (zink) or metal2vulkan as
     Pong does it — a much larger change than the probes above.
- **The a7xx CP has two threads and the kernel must pin one.** BR (render) and
  BV (visibility) share the ring. Mesa GL emits
  `CP_THREAD_CONTROL(BR|CONCURRENT_BIN_DISABLE)` for a7xx and our submit frame
  does the same (`gputhread=1`, the default), Turnip's single-threaded
  configuration. BV never advances (`bv_rptr` stays 0) and
  `CP_THREAD_CONTROL(SYNC|BOTH)` stalls while BV is not started, so nothing may
  sync the threads. `gputhread=2` reproduces kgsl's `BOTH` + IFPC marker frame.
- **The vendor SQE blob cannot load draw-state groups.** The blob from the
  vendor partition (74 672 bytes, payload `58 01 73 01`) refuses
  `CP_SET_DRAW_STATE` with a real group whatever its address or count; the
  linux-firmware one (75 920 bytes, payload `81 01 73 01`) boots identically
  and takes them. The driver ships the upstream blob.
- **`CP_PROTECT` is not the problem.** The packed table in the driver is
  exactly the vendor's `gen7_0_0_protected_regs` (`start | count << 18 |
  noaccess << 31`, e.g. `0x13fc0000` is start 0 count 0x4ff and `0x0160050b`
  is start 0x50b count 0x58, ending at 0x563), and `CP_PROTECT_CNTL` is the
  vendor's 0xb.
- **Protected mode matters, and the frame does not enter it.** With
  `CP_PROTECT_CNTL` enabled and no way out, Mesa's type-4 register writes are
  refused, which is what kgsl brackets a submission for; kgsl still runs every
  submission with protected mode off, and with `cpapriv` on our frame carries
  no `CP_SET_PROTECTED_MODE` at all.
- **An Xcode update silently breaks both build trees.** The Mesa cross file
  (`out/mesa/cross.ini`) bakes the absolute SDK path, so once Xcode replaces
  `iPhoneOS27.1.sdk` with `27.2` every compile fails with "`time.h` not found".
  Point the file at `iPhoneOS.sdk` (the symlink) and delete
  `out/mesa/build-softpipe-freedreno` before rerunning `tools/mk-mesa-ios.sh`:
  reconfiguring the old build directory keeps the cached SDK path and
  `/usr/bin/bison` (Bison 2.3, which rejects Mesa's `%code`), both measured.
  The kernel build uses Xcode's `iig`, and a newer `iig` emits `.iig.cpp` that
  expects an `IORPC` with `kernelContent`, which this XNU does not have; with
  the same Xcode version it compiles. Both failures look like source errors
  and are not.
- **CoreAnimation's client arrays crashed Mesa's state tracker.** CA draws
  with client arrays on the default VAO (`buffer 0`, client pointer, stride
  48), but `vao->VertexAttribBufferMask` had the VBO bits set, so the
  `ALLOW_USER_BUFFERS=0` template called `_mesa_get_bufferobj_reference(NULL)`
  and died at `0x18` in libOSMesa (`ldp [x22,#0x18]`), from `st_prepare_draw`.
  `tools/mesa/mondrian-darwin.patch` recomputes the enabled bits of the mask
  from the bindings before the template is chosen, and `setup_arrays()` uses
  `attrib->Ptr` whenever the binding has no `BufferObj`. Symptom without the
  fix: `mondrian-crash: signal 11 at address 0x18` on every CoreAnimation
  draw, none of the port's own draws.
- **The packet-level tools** are `tools/pm4-decode.py` (names every packet from
  Mesa's `adreno_pm4.xml`, honouring the a7xx variants of a number),
  `gpupm4=N` (truncate a submitted stream to N dwords) and `gpunoblit=1`
  (rewrite `CP_BLIT` to `CP_NOP`). The user client also dumps the first
  streams, the nested `CP_INDIRECT_BUFFER` target and `CP_IB1/IB2_REM_SIZE` on
  a failure; that is how the offending packet was found.
- **An uncached client mapping costs seconds per readback.** The user client
  mapped its buffers with `kIOMapInhibitCache`; reading CoreAnimation's
  1440x3200 surface back (18 MB, BGRA) then took 5.7 s per frame and the swap
  rate measured zero, while the CP finished each submission in 1 ms. The
  mapping is cacheable now and coherency is explicit: `bufferSync()` writes a
  buffer's lines back before the CP fetches it and drops them again on
  CPU_PREP, both `flush_dcache64` by physical address, the pair
  `msm_gem_submit` performs around `dma_buf_end_cpu_access`. The first eight
  CPU_PREP calls log their wait and sync cost in microseconds.
- **The no-copy path works, and so does the draw.** With the CP started
  (`MondrianGPU` published) and `mondrian-gl.dylib` loaded, a frame is
  `1 drawn in place, 0 pictures copied out` and the copy costs 39 µs, so the
  5.7 s readback is gone. The first stream that draws (`168 dwords`:
  `CP_SET_DRAW_STATE` + `CP_DRAW_INDX_OFFSET`) used to eat both indirect buffers
  (`ib1/ib2 rem 0`) and never fence (`int 0 fault 0 protect 0`), which `0191`
  turns into a stopped GPU. It completes now, and so does every stream after it:
  measured `uc big 168 dwords ... done 1 in 1 ms`, then 164/71/67 dwords, 30
  frames and 18 display swaps in one boot. `gpuinit=1|2` was in place for the
  boots that wedged, so hardware init was never the blocker.
  `gpupm4=N` truncates the stream and `tools/pm4-decode.py` names its packets.
- **The keepalive decides whether a boot survives, so it is held.** Same
  kernel, two boots: with the toggle (`gpukeep=0`, kgsl's raise-before and
  drop-after) the boot dies about 70 s in, right after `backboardd` loads
  `mondrian-gl` and before any client submission, and the ring ends without the
  `MONDRIAN RESET: BCB` line; with the keepalive raised at `cp start` and held
  (`gpukeep=1`, the default since `0215`) the same kernel draws 30 frames and
  swaps the display 18 times. A GPU register access while the GMU has the core
  collapsed hangs the CPU that issued it — the user client's first one is
  `MSM_PARAM_TIMESTAMP`, which Mesa asks for as soon as it opens the device —
  so `gpukeep=0` also brackets every such access the way kgsl does in
  `gen7_irq_handler` (`adreno_gen7.c`). `gpukeep=2` never raises it, the A/B.
  `0317` moves the mode to run time (`gpukeep 0|1|2` on the USB channel) and
  waits for GX to report up after a raise (`GMU_OFF(0x1f8d0)` bits 0/1: GDSC
  off, clock off), which is how the release was tested on a live system
  (`docs/MONDIAN_POWER.md`, "Heat"): the hold can come down without a reboot, but
  a blank-triggered drop faults, so the submit path has to bracket its ring
  writes first.
- **The keepalive does not keep GX up.** `gpustat` (0317, on the USB channel)
  with the keepalive held and then released for 58 s while the screen idled:
  `gxclk 0x0 keep 0x0 pwr 0x0 cp2gmu 0x4 rbbm 0x1` at every sample, and the same
  with the IFPC bracket on (`gpunomark=0`, logged as `nomark 0`). GX's GDSC and
  clock stay on, the GMU's RPMH power state never reaches IFPC and the CP never
  sits in IFPC, so the drop saves nothing: entering IFPC is the GMU's decision
  and nothing the port does asks for it. `0317` is still the right shape (the
  wait and the per-submit bracket), but the collapse itself needs the GMU side
  (`docs/MONDIAN_PORT.md` item 9 in `~/.opencode/plan`), not this register.
- **The IFPC bracket is not what the draw needed.** `0203` leaves kgsl's
  `0x101`/`0x100`/IB1LIST bracket off by default (`mondrian_uc_nomark = 1`), so
  the boot that first drew ran without it; `gpunomark=0` turns it back on for
  the A/B. The readiness the patch README credits is the ring wrap with
  backpressure (`0204`), the 512 KiB CP page-table region (`0206`) and the IOVA
  range reuse (`0207`).
- **A ring that ends without `MONDRIAN RESET: BCB` is a boot that died.** The
  reset thread flushes the whole ring and prints that line when it fires, so a
  complete boot ends with `MONDRIAN RESET: fastboot in N s` and the BCB line.
  The phone still comes back to fastboot without them — the watchdog does it
  minutes later, from the BCB a previous boot left — and everything in the ring
  is what the CPU wrote before it stopped. Read the last line as the place it
  died, not as a slow boot.
  The 27-group `CP_SET_DRAW_STATE` in that stream's nested indirect buffer is
  expanded into plain type-4 writes at both levels now, but the rewritten stream
  is wrong: with the expansion on, the 71-dword stream that completes on its own
  stops answering too, so it stays behind `gpunostate=1` until the rewrite is
  right.
- **The CP is what kills the boots that show nothing.** With `gpu=0 gpupower=0
  gmustart=0 gpugx=0 gpucp=0 gpusubmit=0` a boot always reaches userland and
  arms the console ring (measured: the ring's flush count advanced, 178 s, 119
  processes); with the CP on, most boots never arm it. The ring is armed at the
  end of the UFS probe, *after* the GPU bring-up, so a CP wedge is invisible on
  disk — the panel shows the shim's dark clear and the phone resets into
  whatever `boot_b` holds (the recovery on this phone, see `README.md`).
- **A wedged submission has consumed its IB and waits on an event write.**
  In a boot that did reach userland: `uc big 71 dwords ... done 1 in 13 ms`
  passed, `168 dwords ... done 0 in 300 ms` did not, with `CP_IB1_REM_SIZE` 0
  (the SQE read every dword) and the stream's last packet a `CP_EVENT_WRITE7`
  to `0x10408000`, a buffer first used by that submission. `0185` invalidates
  the CP's SMMU ASID when the tables change, which is the candidate fix.
- **A wedged CP takes the CPU with it, and the doorbell is where.** A ring from
  a CP boot ends in one of three places: at `uc pre N` with no `uc big` line and
  no timeout, at `uc big N dwords ... done 0` with the fence unanswered, or at
  `uc door posted N` with nothing after it. The first is the worse one —
  measured with a healthy keepalive (`cp keepalive held up`, `gfx pwr clk 0x0`
  at `cp started`) and the UI frozen at 0 fps: the `CP_RB_WPTR` write, or the
  read-back after it, never returns. A stalled register access hangs the CPU
  that issued it, so the reset thread (`mondrianreset`) never reaches its BCB
  write, the watchdog reboots into `boot_b`, and the phone loops into the shim
  until someone holds power+volume-down. `gpurback=0` drops the read-back (the
  `dsb` already ordered the write) and that is the default.
- **Writing the doorbell from its own thread is a regression, not a fix.**
  Measured on one kernel with the same 71-dword stream: written by a thread
  (`gpuasync=1`) the ring shows `uc door posted 2001` and stops — no fence, 0
  fps, no frame drawn; written inline (`gpuasync=0`, the default) the same
  stream finishes in 14 ms and the UI runs at 26 fps. The thread exists for
  measuring a stall, not for booting, and it must never log: a `printf` plus
  flush from it cost a UFS write per door over the 2000-door bring-up loop, held
  `mondrian_ufs_lock` across the bounce-buffer write, and the boot then ended one
  line after the first client door.
- **The stream that draws is the one that used to wedge.** The 71-dword stream
  is `CP_SET_MODE`, `CP_THREAD_CONTROL`, `CP_SET_AMBLE`, register-only nested
  IBs, a `CP_BLIT` and event writes; it always completed. The 168-dword stream
  adds `CP_SET_DRAW_STATE` (81 dwords, three state groups) and
  `CP_DRAW_INDX_OFFSET` in its nested IB at `0x10434000`, and without the IFPC
  bracket the CP never came back from it. A draw is the first thing that puts
  UCHE/RB/SP/TPL1/GRAS to work at the chip's bank interleave, which is why the
  packet that stopped the CP was the one after the state groups.
- **A ring packet goes at the CP's cursor, never at a saved one.** The
  bring-up stress leaves the CP at `mondrian_uc_at` (`0x5b0`); writing
  `CP_ME_INIT` at the ring cursor the function started with (25) and then
  storing that lower value into `CP_RB_WPTR` makes the SQE reinterpret the ring
  from a point the CP has already passed. Measured as `cp me init rptr 1456
  wptr 35`, and the next client stream never fences. Any raw block appended to
  the ring must start at `mondrian_uc_at` and write it back.
- **An uninitialised CP still fetches, executes and fences.** Measured over the
  2000-submission bring-up loop: `CP_MEM_WRITE`, `CP_EVENT_WRITE`, IB fetch and
  fences all work without `CP_ME_INIT`, so none of those is what the draw stream
  is missing.
- **The panel geometry is right; the textures are not.** In a boot that reaches
  userland the compositor swaps `surface N 1440x3200 fmt 0x62336138 bpr 5760`
  with a full-screen `a 0,0 1440x3200` rect. What is on the panel is the content
  of that surface, and the draws that fill it now run on the GPU: the lock
  screen's first frames are `136 GL calls, 4 draws, 8 triangles` and later
  `316 GL calls, 44 draws, 228 triangles`, with the clock's glyphs white and in
  place. The wallpaper is black because nothing ever draws it (see the
  CollectionsPoster bullet below), so the panel shows the poster surface's
  memory: zeros give the black wallpaper, and `gpusurfpat=1`, which fills a
  fresh surface with `0xffffffff`, gives the white one the port used to report
  as a texture-upload failure. Geometry is not the fault line.
- **Installing the userland into the root image is one pass.** Mesa's
  `libOSMesa.8.dylib` goes to `/usr/lib` (its install name), the UI hook and
  the GPU test to `/usr/libexec`:
  `sudo tools/install-userland.sh IMAGE --ui-hook HOOK --gpu-test TEST
  --mesa out/mesa/stage`, then `tools/mk-simg.py` and
  `tools/flash-root.sh`. The kernel only injects the UI hook
  (`mondrian_ui_hook`), so everything else hangs off it.
- **A lock-screen frame costs its submissions, not its draws, and the
  writeback was the submission.** Measured with the secure-mode switch on and
  the compositor drawing through the GPU: `0 pictures copied out, 1 drawn in
  place`, 25-47 draws and 182-1122 GL calls a frame, the panel copy 2-6 ms and
  `late avg` 8-17 ms. `gpusubtime=1` (`0251`) then put 93 % of every submission
  in `bufferSync`: 84 MB written back per submission, 1773 us at the median and
  7875 us at p90, because every buffer the task had mapped was written back on
  every submission -- including the two 23 MB surfaces the compositor renders
  into, which the CPU never wrote. `gpusyncmapmax=8192` (`0252`) stops that
  for mapped buffers above 8 MiB and leaves the small ones (poster, textures,
  staging blob, command buffers) exactly as they were: the same boot measures
  409 us at the median, 2248 us at p90, 22.8 MB a submission, and the frame's
  `glFlush` falls from p90 25.9 ms / max 213 ms to p90 5.3 ms / max 9.9 ms
  with no other change. What is left of the frame is the `waiting` slice,
  8-18 ms, which is the blit into the surface plus the fence that sends the
  batch on (`glsync=0` drops the fence).
- **The frame rate is set by SpringBoard's main run loop, not by a missing
  display link.** Measured with `CADisplayLink`s of the probe's own
  (`mondrianlink=1`): the link exists, `duration` is 16 ms, and on a thread of
  its own it ticks thousands of times a boot, so CADisplayLink is neither
  absent nor kernel-driven -- it never asks the framebuffer for vsync (`sel
  9:0` and `72` uncalled in every second) and `mach_wait_until` fires exactly
  once a second (`wait` matches the seconds elapsed), so the kernel's deadlines
  are fine. In the same boot backboardd's main link runs while SpringBoard's
  does not: one cache dump per second reads `link pid 27 main 2 own 932 timer
  18 wait 72` -- the main run loop serves a 1 Hz `NSTimer` 18 times in 72 s and
  the 60 Hz link twice, and between those it is blocked. Frames follow it:
  the same boot swaps in bursts of 3, 30, 1, 30 fps and nothing in between
  (147 seconds of `fps 0` when the loop never ran). The digitizer is not the
  wall either, but the reader was: the part sends at its configured rate
  (measured, ring240: `touch 360/s`), while the report thread only read when the
  interrupt line happened to still be low at the look and delivered 10-25
  reports a second during a drag (ring239) -- a scroll that steps every 40-100
  ms whatever the frame rate. Reading on every look while `was[]` says a finger
  is down (`0271`) is what lifts it to the part's rate; the high-rate command
  (`0xC0` to the IC, 240 to 480 Hz) is not needed for 60.
- **A volume written by `--flash` needs two boots.** The first boot after the
  whole-partition write draws nothing at all (`fps 0` for 147 s) and kills
  `mobileactivationd` (`exit mobileactivation[137] status 0x9`) while it
  creates the containers and the activation ark; the second boot draws (bursts
  of 27-30 fps) and the links run at 40+ ticks a second instead of 7. Reflash
  only when the root has to change, and read the frame counters from the
  second boot onwards.
- **The ring wraps the way kgsl wraps it, and that is enough for 8 laps.** The
  symptom used to be a frozen UI a few seconds into a boot: `submit failed: -5
  (Operation not supported)` from the mesa shim, which is the only submission
  exit that maps to `mondrian_gpu_uc_submit() != 0`, and then every later
  submission refused while the display link kept ticking at `dur 16`. The
  cause was the lap boundary, not the surface path. At 32 KiB and at 128 KiB
  the CP retired the lap, walked into the tail and never fetched the first
  packet of the next lap (`uc retired 3941 of 3989, wptr 0x180` with `fault
  0x0 fsr 0x400`, ring218; `uc lap 1 closes at 0x1b40`, ring214). The port had
  been publishing `CP_RB_WPTR = RING_DWORDS` so the CP would fetch the tail
  first; that value is what breaks it. kgsl never writes it: one `CP_NOP`
  reaches the end of the ring, the cursor restarts at 0, and only the small
  wptr of the next submission is published (`0266`). Measured after that change
  (ring219): 8 laps closed, 0 fence-gate refusals, 0 submit failures, and 121
  of 217 one-second samples at 55 fps or more, steady 63-64.
  **`CP_RB_RPTR` cannot be the ring's flow control on this part.** Measured with
  `uc prog` (ring207): inside a lap it tracks the cursor (`at 0x810 rptr 0x7b4`,
  `at 0x1010 rptr 0x1004`, `at 0x1810 rptr 0x1808`), then reads `0x0` for the
  whole next lap, and at another boundary reads `0x1fe9` with the cursor already
  back at `0x28`. A room test on it either waits two seconds a submission
  (`uc no room at 0x1fe8 rptr 0x0 room 23 seq 2040`) or believes the ring is
  empty a lap early. Backpressure is therefore the fence ring: at most 48
  submissions unanswered, so under 400 dwords of ring in flight whatever the
  ring's size, and the cursor is published inside the buffer
  (kgsl `_wptr % KGSL_RB_DWORDS`, HakiOS `ring_at`).
- **The icons exist; a folder's composite does not.** Measured (ring210, with
  `-[SBIconView setIcon:]` hooked): SpringBoard builds the home screen --
  `iconModel -> 1 leaf 13`, `rootFolder -> 1 leaf 9`, 79 `setIcon:` calls, the
  first with an `SBApplicationIcon` -- so what is missing is not the model and
  not the view tree, which the red probe layer proves backboardd composites.
  App icons do reach the glass now (measured 2026-11-18: Photos, App Store,
  Settings, Phone, Safari and Messages all draw their artwork), out of the
  shared icon cache dated 2026-10-28. A folder's icon is a composite of its
  members and is not in that cache, so it shows the placeholder `No content
  available` -- not because the folder is empty, since its member icons draw.
  The Photos app opens and stays blank under the same limit -- its
  `fileproviderd` and `PhotosFileProvider` abort instead of serving the library
  -- and `docs/UI_PERFORMANCE.md` has that measurement.
  What is still missing is the service side a live composite needs, and it fails
  the same way in several hosts. Measured 2026-11-18: `assetsd` does run, then
  aborts (`CRASH assetsd sig 6`) and is reaped as `exit assetsd status 0x6`; the
  three speech plug-in hosts (`SiriTTSSynthesizer`, `KonaSynthesizer`,
  `MacinTalkAUSP`) abort with a frame-pointer chain identical byte for byte. Read
  `status` as `p_xstat`, not as an exit code: 0x6 is SIGABRT, 0x5 SIGTRAP
  (watchdogd), 0x9 SIGKILL -- `iconservicesagent` did not die at all in that
  boot, and the 0x9 one was `driverkitd`. The exception behind the aborts is
  uncaught (`docs/UI_PERFORMANCE.md` has the frames), and naming it needs a probe
  inside the process; the hook is injected by `mondrian_ui_hook`, a bitmask whose
  6 means backboardd and SpringBoard only, so widening it puts our code inside
  the process being measured.
  Ask `-[SBIconView iconImageView]`'s `image` and paint the
  view's own layer (`mondrianiconpaint=1`) to tell "no image" from "not in the
  composited tree" -- a red square where the icon belongs means the view is
  there and only the image is missing. Note that `image 0 contents 0` in the
  probe is not evidence either: the icons that print it draw anyway, because
  the bitmap reaches the layer by a path those two accessors do not see.

  Two traps when probing this, both paid for: `-setIcon:` is the moment the
  view has the model and **not** the artwork (the image is set afterwards from
  the icon's cache), so reading `image` there always says 0; and the first
  eight views must not be kept by pointer -- SpringBoard frees them, so the
  array first names whatever object took their memory (measured, ring220: the
  class dump answered `CSCoverSheetView`) and then, once the probe runs early
  enough, messaging one of them is a `SIGSEGV` in SpringBoard (`ns 2 code 0xb`,
  ring223, three restarts in a row). Keep nothing: walk the windows' subtree
  for `SBIconView` at probe time. A subclass in this userland declares almost
  nothing itself (`SBApplicationIcon`: two own methods), so the artwork
  selectors have to be read up the whole class chain.

  The artwork itself once worked, which dates the regression: the shared icon
  cache (`/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.
  lsd.iconscache/Library/Caches/com.apple.IconsCache`) holds **24 `.isdata`
  entries, all written on 2026-10-28**, one home screen page's worth, and
  nothing since -- and 2026-10-30 is when CoreAnimation moved onto the GL
  compatibility profile. So a boot that draws nothing icon-shaped is not
  "IconServices never ran": it ran and cached the page, and the present path
  stopped showing it. Check the cache dates before blaming the artwork.

  **The bitmap SpringBoard cannot make is the one that matters.** A boot that
  lays out the home screen with the panel itself declared as the screen raises,
  inside SpringBoard:

  ```
  _SBFCGBitmapImageCreate: requested slot length (64512) larger than maximum
  slotLength (57600), not large enough for A8 context with dimensions
  {84, 84} @3.000000x
  ```

  an uncaught `NSInternalInconsistencyException` that aborts the app
  (`ns 2 code 0x6`, then `exec SpringBoard`). 64512 is a 252x252 A8 bitmap plus
  its header and 57600 is exactly 240x240 -- an **80 pt icon at 3x**. The pool
  is sized for an iPhone's icon while the request follows the screen: at
  1440x3200 = 480x1067 pt SpringBoard asks for an **84 pt** icon and no icon
  image is ever created, whatever the artwork says. Declaring the iPhone X
  canvas is the fix for the boot, and it is measured (ring225,
  `mondrianfb_canvas_w=1125 mondrianfb_canvas_h=2436`): the assertion
  disappears, SpringBoard stops restarting, and the dock views come out at
  `70,17 60x60` with the folder at `197,71 155x169` -- the 60 pt layout the pool
  and the userland were built for. The 84 pt request has not gone away, it is
  only not reached; anything that makes SpringBoard rebuild an icon image brings
  it back (see below). Read this before touching icon artwork.

  The canvas costs a scaled `swap()`, and making that copy cheap took three
  measurements that each named a different cost. `drow[x] = srow[x * width /
  fWidth]` is a 64-bit divide per output pixel and arm64 has no such instruction
  (ring225: `fps 26 copy avg 24391 us` against `fps 63 copy avg 2853 us` at the
  unscaled panel). With a two-accumulator DDA in its place the copy did not
  improve (ring226: `copy avg 25351 us`), so the store was the next suspect --
  but assembling each row in cached memory and `memcpy`-ing it did not improve
  it either (ring228: `copy avg 18326..31514 us`, `fps 24..39`), because the
  scalar row build is 4.6 M iterations before the copy even starts. Four pixels
  per 16-byte store, straight into the panel, got it to `copy avg 7585..12324
  us`, `fps 45..56` (ring229) -- still far from the `fps 63-64` of the unscaled
  panel. Splitting the number (`0269`, `clean avg`/`scale avg` on the fps line)
  named the cost: the per-swap cache clean is `736..1008 us` and the scale was
  `9135..13127 us` of the same swap (ring231, `fps 51..60`), so the clean is
  noise and the DDA's serial accumulator chain was the whole remainder. `0268`
  now builds the column map once (`fColMap`: source column of every panel pixel)
  and the inner loop is four loads, four table lookups and one 16-byte store,
  with no dependency chain between output pixels -- `scale avg 4.9..8.1 ms`,
  `fps 56..61` (ring232). 1440/1125 is exactly 32/25, so a row is 45 identical
  blocks of 32 outputs taken from 25 inputs and the block is spelled out with
  constant indices, no lookups; that path is taken for any canvas whose ratio
  is 32/25, and the map remains the fallback. With it the scale is `2.9..5.4 ms`
  and the frame rate `63-64` (ring233); spelling the block out in 16-byte lanes
  (`0272`: one load and one shuffle per four outputs, 8 loads and 6 shuffles a
  block) takes the scale to `1.6..2.1 ms` and the whole swap to `2.2..2.8 ms`
  (ring241), against the 2.85 ms the unscaled panel pays for its `memcpy`. The
  iPhone X geometry is the default in `tools/boards.py`.

  A rate is not a cadence, and the frame rate was the last thing to blame for a
  drag that stepped. The fake vsync re-armed itself with `setTimeoutUS(16667)`
  at the end of its own callback, so every period was that plus the callback's
  duration, and a slow callback moved every later tick with it: a drag measured
  `fps 59` and `gap avg 17709 us`, with a third of the intervals between 20 and
  33 ms (ring242). `0274` arms the timer against a deadline chain -- `fNextVsync`
  advances by exactly 1/HZ, and a deadline an overrun passed is skipped rather
  than fired in a burst -- and prints it as `vsync avg/min/max` (ring243:
  `avg 16666`, min/max `15.7/17.7 ms`, `over17` 0-4 a second). The finer frame
  histogram named the rest: one second of a drag read `lt15 23 15-18 12 18-21 9
  21-26 8 26-34 4 gt34 2` -- frames 8 ms and 21 ms apart in turn -- and the
  cause was the input, not the renderer. The UI redraws once per touch event,
  and the report thread woke about twice a frame and published a position on
  every wake: 85-120 events a second, `ev gap avg 11.7 ms` with 27 of the
  intervals under 10 ms (ring243), a step, a half step, a step. `0276` counts
  display ticks in `mondrian_touch_vsync()` and publishes the newest position
  once per tick, so a frame's worth of motion is one event however often the
  thread wakes; reading still drains the part (360 reports a second measured).
  A drag that steps while `fps` reads 60 is an input-cadence problem: read
  `ev gap` before touching the renderer.

  The presentation was the rest of it, and it was one slot deep. `0279` moved
  the copy to the display tick, and `0281` counted what each tick was handed: in
  a drag, 8 ticks a second got two finished records and 8 got none (ring247). One
  pending slot can only drop the older of a pair and then hold the survivor for
  two periods, so the panel shows 4 ms and then 33 ms, which is the step the hand
  reports -- the fps line reads 60 and the cadence is wrong. `0282` keeps two
  finished records, presents the older at the next tick and the newer at the tick
  after, and a burst spreads out instead of collapsing. Measured over 64 s of a
  horizontal drag (ring251): 3591 frames drawn and 3590 presented, `drop 0`, and
  `pgap over30` -- frames the panel held for two periods -- 8 a second before and
  1.3 after. What is left is arithmetic: a renderer that produces 59 frames a
  second cannot fill 60 ticks without holding one, and `pgap over18` equals
  `pgap over30`, i.e. there is no 18-30 ms hold at all, only the ticks that were
  handed nothing. Two slots is a limit, not a tuning choice: the compositor
  alternates two display surfaces, so a record held longer than one period would
  name a surface that has already been drawn into again (and `drop` stayed 0, so
  a third slot would never have been used).

  Measuring any of that needs something that draws, and the home screen does not
  move by itself: it has one page, so a horizontal drag on it pans nothing and
  `fps` reads 0 while the pipeline is fine. That is the same trap as a static
  lock screen, and it is what rings 248-250 and 253 measured -- boots that had
  unlocked to a page with nothing on it to move. `mondriananim=1` is the harness:
  one animated layer of the hook's own in SpringBoard's window, so the icons, the
  dock and its blur are redrawn every frame for as long as the boot lasts.
  Measured that way (180 s from the unlock): **59.9 fps, 173 of those seconds
  at exactly 60, `drop 0`, `pgap over30` 0.05 a second, and `rec1 60` on every
  tick** -- one record per tick, presented at the tick it was made for. At 60
  fps a swap is 1.5-2.8 ms of copy, 1.2-1.8 ms of scale and 0.3-0.5 ms of cache
  clean, and a swap that arrives after the last vsync is 8-12 ms late at the
  median (16-17 ms worst). That is the number to regress against; a boot with a
  finger on it measures whatever the finger found.

  The artwork used to be painted after the unlock, which put eight PNG reads and
  their decode inside the unlock animation: the transition then held 4-10 frames
  a second (ring252, the first ten seconds after `lock screen gone`) while a drag
  on the lock screen held 1.3. The home screen tree is behind the lock screen, so
  the pass runs from the first step after twenty seconds instead, and the
  transition's first second reads 61 fps with no frame held.

  Where the artwork goes, when it is injected by hand -- and why it cannot be
  SpringBoard's own view. `-[SBIconView iconImageView]` answers without an image
  in this userland, and the descendant that takes `-setImage:` is the *label's*
  image view (measured, ring226: `App Store set SBIconLegibilityLabelView`, a
  74x21 label). Writing either is worse than useless: SpringBoard reacts by
  rebuilding the icon at the model's image info, and that is 84 pt, which the
  pool refuses -- 52 `requested slot length (64512) larger than maximum
  slotLength (57600)` assertions and 24 SpringBoard restarts in one boot
  (ring227, after a second painting pass twenty seconds in). The artwork
  therefore goes into a `UIImageView` of the hook's own, tagged `MON1` and added
  at the icon view's bounds: a layer nobody else owns, so the compositor draws
  it and no icon image is requested. That is measured to work (ring228): six
  icons painted, SpringBoard with zero crashes, and twenty seconds later
  `icon Photos own 1 image 1 contents 1` -- the view is still ours, still holds
  the image, and the layer has contents for the first time on this port.

- **The panel is command mode, and the kernel kicks it.** A store into the
  framebuffer memory never reaches the panel: the DSI interface takes one
  `CTL_START` per frame, which is why a frozen display is not a dark one. The
  ABL leaves the DPU scanning a 43 MiB splash carve-out at `0xb8000000`
  (`0x2b00000`), measured as SSPP0 and SSPP1 `src0 0xb8000000`,
  stride `0x1680`, `fmt 0x237ff`, and the kernel writes the same memory
  through the early WC alias. The trap -- the bootloader's
  `INTF_TEAR_AUTOREFRESH_CONFIG = 0x8000003c` and `INTF_TEAR_CHECK_EN`, which
  must be cleared before the first start of the session -- is in `NOTES.md`
  ("Display"). CTL0 is the active controller (`ctl0 top 0x100002d active 0x2`),
  INTF1 the interface, and `INTF_DSI_CMD_MODE_TRIGGER_EN` is `0x084`.
  DSI0 is at `0xae94000`; the registers worth reading are
  `STATUS0` `0x004` (`CMD_MODE_ENGINE_BUSY`, `CMD_MODE_MDP_BUSY`, `DSI_BUSY`),
  `FIFO_STATUS` `0x008` bit 7 (`CMD_MDP_FIFO_UNDERFLOW`), `CMD_DMA_CTRL`
  `0x038`, `CMD_MDP_STREAM0_CTRL` `0x054`, `CMD_MDP_STREAM0_TOTAL` `0x058`,
  `ACK_ERR_STATUS` `0x064`, `TRIG_CTRL` `0x080`, `DLN0_PHY_ERR` `0x0b0`,
  `TIMEOUT_STATUS` `0x0bc`, `RESET` `0x114` and `CLK_STATUS` `0x11c`. A wedged
  interface reads `STATUS0 0x1f5` (busy bits set); that is a diagnostic, not
  the idle value.
- **A sleeping display stops every CADisplayLink, and the fix is the
  `UIApplication` idle timer.** About fifty seconds after the unlock,
  SpringBoard arms its idle timer and the backlight state goes off; this tree
  has no backlight device (`backboardd` logs
  `path IODeviceTree:/backlight -> none`), so every link in the system stops,
  the framebuffer keeps the last frame, and frames stay at 0/s while the panel
  is still kicked at 60 (measured: 138 s uptime, unlock at 88 s; NSTimers keep
  their rate). The hook first wrapped `-[SBUserAgent
  setIdleTimerDisabled:forReason:]`, which nothing ever calls; it now sets
  `-[UIApplication setIdleTimerDisabled:YES]` on the shared application every
  2 s from the lock step, and re-requests the unlock every 60 s while the lock
  screen is up instead of three times. Not boot-verified. `mondrianwake=N`
  does not fix it: it presses the power key, which locks a lit device as often
  as it wakes a dark one. Leaving the lock screen is the harder half:
  `-[SBLockScreenManager unlockUIFromSource:withOptions:]` returns 0 for every
  call and each refused call counts as a failed attempt, which after thirteen
  of them left the screen saying "iPhone is not available" and refusing
  everything (ring199). That flag pair lives in
  `/var/mobile/Library/Preferences/com.apple.springboard.plist`, where
  `SBDeviceLockBlocked` **true means the device is blocked** (it is the
  "unavailable" state, not "block locking": see pwnboot's
  `docs/lockout-reset.md`) and `SBDeviceLockFailedAttempts` counts the
  refusals; a hook that writes `SBDeviceLockBlocked` = `true` puts the device
  into that state by itself. Write `false` and `SBDeviceLockFailedAttempts` 0,
  and unlock through the entry point the swipe uses
  (`-lockScreenViewControllerRequestsUnlock`); that request is repeated once a
  minute while the lock screen is still up, unlike the refused path above.
  Three traps come with this hook. `+[SBLockScreenManager sharedInstance]` must
  not run before `+[UIApplication sharedApplication]` exists: from the dylib
  initializer it asserts ("Unexpectedly created SBLockScreenManager before
  UIApplication instance was created") and terminates SpringBoard.
  Every `SBLockScreenManager` call must run on the main queue: from a thread of
  the hook's own it traps in libdispatch ("BUG IN CLIENT OF LIBDISPATCH:
  Assertion failed: Block was expected to execute on queue
  [com.apple.main-thread]", SIGTRAP with `pc` == `lr` - 8) and SpringBoard dies
  thirteen seconds into every launch, which reboots the device in a loop and
  looks like a hang on the Apple logo. And the frame rate needs something that
  moves: a static lock screen draws nothing, so `fps 0` there says nothing about
  the renderer -- `mondriananim=1` puts one animated layer in SpringBoard's
  window to measure the path without a finger on the glass. That layer must be a
  fresh `CALayer` per window, never a copy: the class does not implement
  `NSCopying`, and `[layer copy]` aborts SpringBoard with an uncaught
  `NSInvalidArgumentException` ("-[CALayer copyWithZone:]: unrecognized
  selector") the second the lock screen goes, which shows up as four crashes and
  a spinner while SpringBoard relaunches (ring202).
- **The vsync registration selector is 9, not 72.** The documented
  IOMobileFramebuffer ABI (The Apple Wiki, `Dev:IOMobileFramebuffer`) puts
  `setVSyncNotifications(functionAddress, userData)` at selector 9, with the
  mach port delivered through `IOConnectSetNotificationPort`; the port's
  method 72 takes three arguments and no ABI has it. `0256` implements 9 beside
  72 and counts every selector call. Nothing calls either (`9:0` every second)
  even in boots whose links tick, so the 60 Hz timer in the driver has no
  client and CoreAnimation is not the one that would have been waiting for it.
- **The panel console is silenced when the framebuffer starts, not at the first
  swap.** `mondrianfb_noconsole=1` (in the board cmdline) used to take effect
  inside the first swap, and the UI can go a minute without one, so the HID and
  FB traces stayed painted over the lock screen; `0257` applies the switch at
  the end of `AppleCLCD::start()` and drops the liveness marker with it.
  `mondrian_early_status()` -- the `console N chars/s, M behind` row, painted
  below the text area and outside the console -- ignored the flag and had to be
  gated on the same switch. The ring keeps every line, and
  `mondrianfb_noconsole=0` in the extra args brings the screen console back.
- **The GPU used to sit at its idle OPP for the whole session, and the session
  now votes on its own.** The boot prints `MONDRIAN GPU: hfi power gpu 2 bus 2,
  285 MHz`: the HFI power vote carries perf index 2, which this port's table
  maps to 285 MHz and which kgsl uses while no client asks for anything. kgsl
  then sends a fresh DCVS vote per submission, so on Android the GPU runs at
  the OPP the load needs; here the vote sent when the GMU starts stood for the
  whole session. Measured 2026-11-17 with the same eight page swipes in one
  boot: 285 MHz gives 41-47 fps and 7.1 ms of GPU time per submission, index 13
  (900 MHz) gives 48-52 fps and 2.24 ms -- the 3.2x the clock implies -- and
  the copy to the panel drops from 4.2 to 3.5 ms.
  `0349` sends that vote from the first submission of the session (the state
  kgsl votes in: CP running, a client asking for work) and the boot logs
  `MONDRIAN GPU: active vote 13 (900 MHz) acked`. `gpuactive=N` picks the index
  (`0` keeps the boot vote for an A/B) and `gpuperf N` (`0346`) moves it at run
  time. Index 13 in the *boot* vote is the trap: that message carries the power
  table the GMU builds itself, and the boot then does not come back to fastboot.
  Measured after `0349`, with no ring command at all, the same swipe produces
  55-58 fps with 599 of 600 frames ending on a P core.
  The cost is that there is no down-vote: the GPU stays at 900 MHz while the
  UI idles. A quiet-period timer is the missing half.
  `gpustat` prints the accounting behind the clock (`gpuacct`: submissions,
  dwords, fence waits and their time, doorbell to fence summed against the wall
  clock), which is how "the GPU is 14% busy" and "the frame is still 19 ms" can
  be said in the same breath.
- **The wallpaper is a killed poster, and its renderer cannot work here.**
  CollectionsPoster makes the poster surface (`MONDRIAN SURF: CollectionsPoster
  create id 11 1326x1326 fmt 0x4c303038`) and dies before it draws one frame --
  no `|CollectionsPoste| mondrian-gl: frame` line ever appears. Which kill
  depends on how fast the frames are: with the slow frames of `glcopy=1` it is
  the scene-create watchdog (`reason ns 10 code 0x8badf00d`), and with
  `gpusyncmapmax=8192` it is `reason ns 7 code 0x3: extension check-in timeout`,
  after three poster surfaces in a row. Either way the surface is never filled
  and the panel shows its memory, which is why the wallpaper is black with
  `gpusurfpat=0` and white with `gpusurfpat=1`. AegirPoster's own crash reports
  add the second half: `-[NUNIAegirRenderer
  getOrCreateUniformBufferforFrameBufferIndex:]` throws `-[__NSArrayM
  insertObject:atIndex:]` (22 of them on the root), a Metal renderer indexing
  its uniform-buffer array. The root ships one Metal driver, `AGXMetalA11`, so
  Metal is the A11's GPU and this port draws through Mesa/freedreno OpenGL ES:
  a Metal poster renderer has nothing to talk to. The home screen's correct
  answer here is a still image behind the icons, not a live poster; fix the
  check-in only for the GL extensions. The hook's static wallpaper is that still
  image and draws on the lock and home screens (measured 2026-11-19); the live
  poster remains the open part.
- **One ring, one lock.** Every `MondrianGPU` client (backboardd,
  SpringBoard, the poster extensions, mediaserverd) submits to the same CP
  ring, whose cursor, fence sequence and memptr slots are file-static in
  `mondrian_gpu.c`, but `MondrianGPUUserClient` gave each client its own
  `fLock`: a client only serialised against itself. The ring-room wait is
  1 ms-polled and gives up after 2 s.
  The firmware blocks, the GMU context bank and the CM3 start
  are in `mondrian_gpu.c` under `gmustart=1`.
- **The present path is the GPU's, measured on the secure-mode boot.** With
  `glcopy=1` a frame is `1 picture copied out` at ~11 ms; with `glcopy=0
  glwait=0` the same boot reports `0 pictures copied out, 1 drawn in place`,
  680-1949 us a frame, and each present is `MONDRIAN FB: swap N layer 0
  surface X 1440x3200`. A still screen then stops swapping after five or six
  frames (`fps 0`): that is CoreAnimation drawing only on change, not a stall,
  and no process dies. Frames per second under motion has to be read with a
  swipe or an unlock running, because a lock screen at rest never asks for a
  frame.
- **GX runs under a submission, and the render blocks run the blit.** The two
  power questions are both answered, so neither is worth re-measuring:
  `GMU_GFX_PWR_CLK_STATUS` reads `0` (GDSC on, clock on) on every fence poll
  while an IB is in flight (`gxsample=1`), and the OR of sixteen
  `RBBM_STATUS` samples taken across an 8 MiB blit is `0xc30df7` -- `RB_BUSY`
  (7), `CCU_BUSY` (8), `RAS`/`TSE` (6/5), `VPC` (16) and `UCHE_BUSY` (17) are
  set while the CP is still executing. The 2D engine, its colour cache and the
  UCHE therefore execute the whole blit; what they do not do is change the
  destination.
- **Nothing but the CP's own writes reaches the destination.** Measured on one
  boot, same buffer, same submission: `CP_MEM_WRITE` canary lands
  (`got 0xcafe1234`), the blit leaves `nonzero 0/64`, an 8 MiB blit leaves
  start/mid/end at zero, `CCU_CLEAN_COLOR` + `CACHE_CLEAN` + `WAIT_FOR_IDLE` in
  a submission of their own change nothing, and a blit into an unmapped page
  raises no SMMU fault. Aiming the blit at the buffer's *physical* address
  (`gpu2dpa=1`) instead of its iova changes nothing either, so the render path
  is neither translated nor bypassing translation: the write never reaches the
  address the instruction names. The loss is inside the GPU, past the RB/CCU.
- **The shader path fails the same way, so this is not the 2D engine.**
  `glselftest=1` clears a 64x64 FBO and reads it back (`clear+read 00 00 00 00`),
  uploads a texel and reads it back (`texsub+read 00 00 00 00`) and draws a
  green triangle over it (`draw linked 1, drew 00 00 00 00`), all with
  `error 0x0`. Shaders compile and link and `glDrawArrays` returns cleanly. Use
  this test before blaming `CP_BLIT`: it separates "the blitter is wrong" from
  "no render block writes memory", and only the second is true here.
- **The two a7xx memory-interface registers mainline writes were already
  right; the GBIF system cache was not, and fixing it changes nothing.**
  `UCHE_CMDQ_CONFIG` (`0x6690e`) and `RBBM_GBIF_CLIENT_QOS_CNTL` (`0x2120212`)
  read back correct before this port ever wrote them (`gpuif=1` writes them
  anyway). `GBIF_SCACHE_CNTL0/1` read `0`, so `gpuscache=1` writes the a730
  LLCC slice the way mainline's `a7xx_llc_activate` does for sm8450
  (`LLCC_GPU = 9`; `CNTL1` with the id in its fields = `0x1294a529`, `CNTL0`
  = `id<<10 | BIT(8)` = `0x2500`), the writes stick and the blit still writes
  nothing. Both flags default on; `gpuif=0`/`gpuscache=0` are the A/B.

### The panel takes a frame on a tick, and the frame cost is the limit

The compositor draws into an ordinary-memory IOSurface; the driver copies that
canvas into the panel carve-out at `0xb8000000` on every present (`mode copy`)
and the 60 Hz timer tick starts the interface. Panel and canvas are the same
size (`1440x3200`, stride `5760`), so the copy is 1:1 and costs 2.8-3.9 ms
(measured 2026-11-17, injector in `backboardd`).

The `swap` records say what that copy is: **one layer, the whole panel**, and
CoreAnimation alternating two canvas surfaces (`s2`/`s3`), so the canvas is
double-buffered by CA itself and the driver's per-layer flattening is not used
in practice. Nothing waited for the submission that named that canvas -- the GL
interposer skips its `glFinish` (a full sync drops the display to about twenty
swaps a second) and this driver never looked at the fence -- so `0350` adds
`mondrian_gpu_retire()`, called once per present behind
`mondrianfb_gpuwait=1`: a bounded wait on the fence the submission path already
handed out. Measured on the lock screen it costs `gpuwait avg 155-447 us` a
frame, because the GPU has usually retired the frame by then; it buys ordering,
not frames, so it is off by default. `mondrianfb_nocopy=N` (skip the copy N
seconds out of ten) measured the copy's share of the frame rate directly: no
gain (54-56 fps with it against 41-59 without, with a worse `late`), so the copy
is not what drops frames and no faster copy is worth writing.

Corruption on the glass -- big diagonal stair edges, black holes, pieces of an
earlier frame -- is not this path: with the geometry intact and the canvas
double-buffered, it is drawn into the canvas, and the failing piece there is the
texture upload (`docs/COREANIMATION_GLES.md`). Check the home screen's frame
cost before touching this driver.

What a swipe looks like in the ring (89-347 touches/s): 47-50 fps, the copy at
~3 ms, the frame arriving 8-12 ms after the tick (mean 8.8, max 16-17), and a
backboardd frame of **14.6-15.6 ms of which 8.5-10.5 ms is the interposer
waiting on the GPU** -- 845-950 GL calls and 150-190 draws per frame, some 30k
command buffers submitted over a boot. With the copy on top, the frame is over
the 16.7 ms period and the panel shows 47-50 fps instead of 60. **The frame
cost, not the panel timing, is the limit**; `clean avg` is 0.5-1 ms and the
scale path is not used.

`mondrianfb_nowait=1` (start the interface from the present instead of from the
tick) was built and booted: it does start a frame per present (`nw 1174` starts
for 1108 interface frames), but it **wedges the interface** -- the CTL's start
bit stays set on a start issued while the previous frame is still going out
(`start 0x1`, `lc 0x616`, `wedged intf`, then the driver's software reset), and
the panel stops. Any version of it needs to gate the kick on the previous frame
having completed, which is what the tick does for free. It is not in the tree.

**A tear was not what the panel showed.** The copy does write the 18 MB the DPU
fetches, and a double-buffered canvas was built for it (two frames inside the
carve-out, the second at `0xb9194000` behind an `IOMemoryMap` with
`kIOMapWriteCombineCache`), but no band was observed on the glass and the
version that ran reset the phone. It is not in the tree. If a band does appear
that is the design to return to -- and the display reads through the
`apps-smmu` (`mdp_0_tbu@151f9000`, `mdp_1_tbu@151fd000` in the live device
tree), so a pipe pointed at the second canvas must be inside the range the
bootloader mapped for it.

The bootloader leaves the interface with `afr 0x8000003c` (autorefresh on) and
the tear check enabled; the driver clears both before the first start. The
panel therefore refreshes on the frames the driver sends and nothing in the
hardware paces it against the glass.

Trap: an IOKit object is not zeroed. The first version of the second canvas
added `fDual`, `fAlt`, `fBasePhys`, `fAltPhys`, `fShown`, `fPending`, `fFlips`
and `fAltMap` and did not initialise them in `AppleCLCD::start()`; a garbage
`fDual` ran the path on a boot that never asked for it and a garbage `fAlt` sent
the copy into memory nobody mapped. Both read as a kernel that does not boot at
all. Every member the driver adds goes in `start()` with the rest.

### Running the GPU test from the UI hook

The UI hook dlopens it in every daemon the kernel injects it into, so there is
no new boot argument; the ring log then holds a `MONDRIAN GPU TEST:` verdict.

```sh
tools/build-mondrian-gpu-test.sh /tmp/mondrian-gpu-test.dylib
sudo tools/install-gpu-test.sh ios16-root.img /tmp/mondrian-gpu-test.dylib
python3 tools/mk-simg.py ios16-root.img ios16-root.simg
tools/flash-root.sh ios16-root.simg
tools/mondrian-boot-log.sh --reset 150
```

### Never call syslog() from an image initializer

`mondrian_inject.c` used to end its constructor with `syslog()`, and on this
port that call never returns: `syslog` -> `libsystem_asl` ->
`os_log_shim_enabled` -> libdispatch waits in `mach_msg` for a service that is
not there. An image initializer holds its process's main thread while it waits,
so every injected daemon (backboardd, SpringBoard, containermanagerd) stopped
inside it on 2026-11-15: backboardd's window server never started, SpringBoard's
main queue never drained (`MONDRIAN UI: lock step stuck`), and the ring showed a
main-thread stack ending in `#12 syslog`, `#13 mondrian_inject`. Use the
`say()` on the line above it: a plain write to stderr and `/dev/console`.

Two copies of the injector are live at once: the kernel injects
`/private/var/vm/mondrian-inject.dylib` into the poster extensions, and the UI
hook dlopens `/usr/libexec/mondrian-inject.dylib` in the daemons. `tools/
usb-ring.py wfile PATH LOCAL-FILE` replaces either copy over the control
channel, and a process that has the file mapped must be killed first (`kill
PID`). A `wfile` into `/private/var/vm` does not survive the next boot: `glblob=1`
writes the kernel image's copy over it as soon as the root turns writable, so a
hook change is `tools/build-mondrian-ui-hook.sh out/gpu/mondrian-ui-hook.dylib`
(there is no xcrun on WSL; the script links with `ld64.lld` there), one kernel
build, and one `fastboot boot` -- a dylib left in `out/gpu/` from an earlier
change is embedded silently, so check the new string is in the kernel with
`strings xnu/out/kernel.development.mondrian`. The ring says which copy is in
use (`MONDRIAN HOOK: <proc> uses the /private/var/vm copy`) and when the blob
lands (`MONDRIAN GLBLOB: ... -> 0`).

### os_log blocks with logd running

The probe in the UI hook answers the graphics side in one boot:
`MONDRIAN PROBE: framebuffer match` (the kernel's `IOMobileFramebuffer` is
published as `AppleCLCD`), `IOServiceOpen -> 0x0` (type 0 opens, so the user
client the window server would use is there), `CAWindowServer nil`,
`CADisplay` (this one blocks) and `os_log enter` / `os_log return`.

Measured 2026-11-15, with `0330` (logd granted and alive, no `exit logd` in the
ring): `os_log enter` still never returns, at t=5 s and again at t=45 s and
t=100 s from their own threads, and `os_log_create` from BackBoardServices holds
backboardd's main thread in `libdispatch` -> `libsystem_trace` ->
`mach_msg` -> `os_log_create`. The boot log has `Firehose configured: 16 chunks,
8 io pages`, which is the *kernel* buffer, so the stack was read as a writer
waiting for a consumer in `firehose_buffer_tracepoint_reserve_wait_for_chunks_
from_logd`. **That reading is wrong.** Measured 2026-11-16 with `msgtracename=logd`
(`0334`): logd is alive and working -- it sends its own request/response pair
(4811 of up to 120 KB, answered by 4911 of 52 bytes) several times a second and
sends id **11702**, the firehose push acknowledgement, to several client ports.
So logd does drain; the process that blocks in `os_log` is blocked on something
else, and the container-manager wait in the same boot is not logd's fault
either.

The firehose MIG subsystem is 11600 (`register`, `push_and_wait`, `push_async`),
replies are +100; a *container* request is id 1000 with an **empty** body (the
reply is 1100), so that channel is not a bootstrap lookup with a name in it and
interposing `bootstrap_look_up` can never see it.

Do not inject the UI hook into `logd` to look at it: the dylib links
CoreAnimation, and a boot with the hook in logd stopped answering on the ring
and on fastboot within a minute (2026-11-15).

Do not interpose `os_log_*` either. A `__DATA,__interpose` table does take
effect -- `backboardd`'s `BKLogCommon` really did call the replacement -- but
forwarding the call needs `dlsym(RTLD_NEXT, ...)`, and that dlsym from inside
every log call deadlocks in dyld. Two boots' worth of "backboardd is stuck in
`os_log_create`" and a launchd whose queue stopped draining were that deadlock,
not the port's. Hook the caller, or read the stall with the sampler, but leave
the logging entry points alone.

### Resolving a port's owner from the sampler

`0332` records the port name of every send the traced pid starts; `0333`
resolves it from the sampler, outside the trap, and prints
`MONDRIAN DEST: pid N port M owner P`, because a send that never completes
never reaches the print that would have named its destination. `mprev/ringpid.py`
turns `owner P` into a process name from the ring's own process list.

The trap that version cost one boot: `ipc_port_translate_send` returns the port
**active and locked, and without a reference**. Unlock it with `ip_mq_unlock`
(there is no `ip_unlock` in this XNU) and never call `ipc_port_release_send` on
it -- that consumes a send right that was not taken and spins on the port's own
lock. The kernel wedges silently: the USB gadget still enumerates as
`1209:0001`, no IP answers, and the ring is gone, which reads like a shim or
payload failure rather than a deadlock in the new code.

### The window server is never asked for

**Start here: this whole section is the hook's doing.** Measured 2026-11-16, the
same kernel, image and board table with one argument changed:

| `mondrian_ui_hook` | backboardd threads | SpringBoard threads | glass |
| --- | --- | --- | --- |
| `0` | 16-19 | 13-14 | lock screen, home screen, Settings opens (`exec Preferences`) |
| `61` (every daemon but backboardd) | 2-7 | 2 | boot console, no layer |

With `0` the compositor submits `MONDRIAN FB: layer 0 surface 2 1440x3200
dst 0,0` 235 times in one dump and the panel shows the live UI, minute clock
included. So the window-server path, the display link, the panel copy and the
app launch chain all work on this port; what breaks them is the injected dylib.
Bisected one bit at a time. With the interposer removed, **`0x4` (SpringBoard
alone) renders**: 108 layers of 1440x3200, backboardd 14-15 threads, the lock
screen, the home screen and an opened Control Center, with the hook's own lines
in the ring (`brightness level hooked`, `display link rates hooked`,
`MONDRIAN TZ: localtime .../US/Pacific -> .../Europe/Madrid`). The bits that
were measured before that fix -- `0x1` leaving 0 layers and SpringBoard 2
threads, `0x4` parking the panel on the Apple logo -- were the stale dylib, not
the bits. `tools/boards.py` carries `0x6` with `mondrian_gpu_hook=1` (`0344`):
bit 2 hands `backboardd` `/private/var/vm/mondrian-inject.dylib` instead of the
hook, which is the only way the window server can pick the GLES renderer
described above; when that blob has not been written yet, backboardd is left
alone rather than handed the hook. Unmeasured as of 2026-11-17, and so are the
remaining bits (runningboardd, launchd, poster, xpcproxy) with the fixed hook.
Measured 2026-11-17 with `0x4`: the compositor stays in `mode copy`, every
`MONDRIAN MEM` sample reads `gpu 0MiB/0`, and the injector the hook loads in
SpringBoard is the stale `/usr/libexec` copy, which returns at once because its
constructor arms for `backboardd` alone.

**The idle blank resets the phone while Mesa renders.** Measured 2026-11-17 with
`mondrian_gpu_hook=1`: `mondrianfb_blank=30` reset the phone about 30 s into
every boot, four boots of four, before the ring answered, and `boot_b` answered
instead; `blank=0` booted the same image twice of twice, with the injector in
backboardd and Mesa drawing frames in the ring. The timer only starts once
`fLastPresentTicks` is set, so the DCS `0x28` goes out while the interface is
presenting. `tools/boards.py` carries 0 until that path is fixed, so the panel
now stays lit when idle.

### The hook that was measured was not the hook in the tree

The kernel embeds `out/gpu/mondrian-ui-hook.dylib` and writes it to
`/private/var/vm` at boot. When that file is missing the kernel embeds nothing,
the device keeps loading the copy an earlier boot left there, and the source
change looks inert. That is what happened here: the running dylib was a build
that still interposed `dispatch_sync`, so SpringBoard's main thread sat in
`mondrian_dispatch_sync -> ChronoServices -> SBSystemAppMain` (the hook's own
`MONDRIAN DL` dump names it) and the panel never left the Apple logo, while
containermanagerd never answered backboardd's container query. The replacement
asks `dlsym(RTLD_NEXT, "dispatch_sync")` from inside `dispatch_sync`, and a
thread that already holds dyld's lock parks there -- the same dyld deadlock the
logging interposers paid for. The interposer is removed; before trusting a
boot's hook, check `nm out/gpu/mondrian-ui-hook.dylib | grep dispatch_sync`
prints nothing and that the ring says which copy the process loaded
(`MONDRIAN HOOK: <process> uses the /private/var/vm copy`).

Test the other bits the same way before reading anything below as a property of
the port.

**A hook change does not need a kernel build.** The injector only tests that
`/private/var/vm/mondrian-ui-hook.dylib` exists, so `tools/usb-ring.py wfile`
replaces it and `kill <SpringBoard pid>` (the pid is in the ring's
`SMP ... SpringBoard(N)`) makes launchd re-exec with the new file; the ring
proves it with `MONDRIAN WFILE ... -> 0` followed by `injected UI hook` and a
new pid. Write first and kill after: a write that lands after the respawn
leaves the old dylib mapped (measured), and `O_TRUNC` on a mapped file can
SIGBUS the process, which is harmless because the respawn loads the new one.
Never leave a truncated hook in place: the existence test prefers it over the
`/usr/libexec` copy and every SpringBoard exec then dies at dyld. A reboot
restores the kernel's copy (`glblob=1`).

With the hook injected, no process in the hook set (`launchd`,
`containermanagerd`, `backboardd`, `runningboardd`, `SpringBoard`) calls
`+[CAWindowServer server]`, measured with a passive hook over a whole boot: CA's
window-server path is not entered at all, which is why no
`IOMobileFramebuffer` selector from the compositor ever arrives (`sel 4:0 5:0
…`), no display link ticks (`DL[57] … ticks/5s 0/0`) and `present` stays 0/s.

Do not call it yourself to "wake it up": a constructor that asks for the server
creates one on the spot and the boot stops answering on the ring before the
first heartbeat pair ends (two boots). Observing is safe; asking is not.

The render server itself is the step before that, and it is missing too:
`CARenderServerIsRunning()` answers 0 in `backboardd` at 20, 40 and 60 s, so
nothing in the system ever created one. Calling `CARenderServerStart()`
yourself (in `backboardd`, through `dlsym(RTLD_DEFAULT, ...)`) returns 1 and
the getter flips to 1 -- it does not block and needs nothing that the port
lacks. `backboardd` simply never makes that call, which is why the compositor
has no server to detect displays into.

**Why it never gets there: the main thread is inside the log call.** That is
what a boot *with the hook in backboardd* shows: `dyld start -->
BackBoardServices -> BKLogCommon -> libsystem_trace -> dispatch_sync ->
mach_msg`, frozen from before userland settles. The same boot with the hook out
of `backboardd` (`mondrian_ui_hook=61`) gets past that and stops one step
further, in `CoreAccessoriesInitForHID`. The dylib links QuartzCore, so an
injected `backboardd` loads images in a different order and the log wait moves
ahead of everything else; read `backboardd`'s own startup only from a boot
where the dylib is not in it.

Naming the queue by interposing `dispatch_sync` does not work: a
`__DATA,__interpose` entry whose replacement calls `dispatch_sync` again is not
re-bound away from the replacement, so the first call recurses until the stack
is gone. Userland then never comes up at all -- the USB gadget still
enumerates, the ring never answers, and there is no panic to read.

### A clean backboardd stops in the accessory init

Measured 2026-11-16 with `mondrian_ui_hook=61`: `backboardd`'s main thread sits
in `CoreAccessoriesInitForHID` -> `CoreAccessories+0x20cf0` -> `dispatch_sync`
-> `mach_msg`, and the window server work never starts. Reproducing the call
from `runningboardd` (dlopen the framework, call the symbol from the hook)
hangs in exactly the same frame, so the wait does not need `backboardd` to be
observed.

It is not an XPC mach service: interposing `xpc_connection_create_mach_service`
in the reproducing process prints nothing while the call is stuck, and the
thread's stack goes straight from the framework into `mach_msg`. The framework
speaks Mach directly to one port, and the hook's next probe reads that port out
of the blocked thread's trap arguments (`mach_vm_read_overwrite` on
`mach_msg2_trap_args.data`, then `mach_port_type`), which says whether it is a
live send right or a dead name.

The on-demand side is not the fault. A first message to
`com.apple.accessories.hid`, `com.apple.accessories.connection-info-server` or
`com.apple.accessories.transport-server` (lookup `0x0`, send `0x0`) spawns
`accessoryd` immediately -- `exec accessoryd` lands right after the send in the
ring, and the fourth send resolves to `owner 128`, the daemon that just
started. So `accessoryd` is available on demand; a clean `backboardd` still
waits after it is up, which rules the demand trigger out as the cause.

### Skipping the accessory init moves the wait, it does not remove it

Measured 2026-11-16 with `tools/mondrian-probe.m` injected into `backboardd`
alone (`mondrian_probe=1 mondrian_probe_proc=backboardd`; the dylib links
Foundation and CoreAccessories and no QuartzCore): the replacement returns from
`CoreAccessoriesInitForHID` and the main thread leaves that wait. The next stop
is the container manager --
`BSSystemSharedDirectoryForIdentifier -> container_system_path_for_identifier
-> ... -> xpc_connection_send_message_with_reply_sync -> mach_msg` -- and 120 s
later there is still no render server (`CARenderServerIsRunning` 0), no
framebuffer selector from the compositor and `present` 0/s. The accessory call
is the first of several synchronous replies `backboardd` waits for at startup,
not the cause of the black screen by itself.

A probe inside `backboardd` is racy: of eight boots with the same kind of
dylib, two reached the accessory call (`loaded` followed by `skipped`) and six
landed in the `BKLogCommon` block before it (`loaded` only). Deferring the
worker threads out of the constructor did not change that, and neither did
turning off `msgtrace`, so the race is between the dylib's own load and logd
being ready, not between the probe's threads. Only a boot whose ring has the
`skipped` line measured the accessory step.

Two build facts, one boot each:

- The interpose only binds if the framework is linked. With
  `-undefined dynamic_lookup` alone, CoreAccessories is not in the image when
  the interpose table is processed, dyld drops the entry, and the dylib loads
  without changing anything. `-framework CoreAccessories` works: the SDK ships
  `CoreAccessories.framework/CoreAccessories.tbd`.
- `container_system_path_for_identifier` is the nearest exported symbol above
  the blocked frame, not the frame itself. Interposing it (with a hand-written
  `.tbd` for `libsystem_containermanager`, so the dylib is loaded before the
  probe binds) prints nothing and moves nothing: the call is an internal
  function that follows that export. The same `dladdr` trap that made
  `os_log_create` look like the logging stall.

The blocking frame is `libsystem_trace + 0x5ccc`, which is **not**
`os_log_create` (that one is at `+0x4000`, and there is a private
`_os_log_create` at `+0x14ac0`). Measured by printing the offsets at runtime;
`dladdr` on the blocked frame names the nearest public symbol, which is why it
reads as `os_log_create`.

Silencing the logging entry points (`os_log_create`, `os_log_type_enabled`,
`_os_log_impl` through a `__DATA,__interpose` table) does not move that frame:
the call is made from another image's initializer, through the private entry.
Interposing `BKLogCommon` itself to return a dummy handle *does* release the
main thread -- and then `backboardd` dies (143 crashes in one boot, and it is
gone from the process table by `t=273 s`), because the handle it hands back is
used somewhere that this port has not silenced. Neither shim is a fix; the
block has to be removed in the logging path itself (the firehose wait that
`dispatch_sync` is sitting on), not stubbed out above it.

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

## Local build inputs

The mailbox-facing headers are generated, not committed: the firmware and the CP
tables are Qualcomm's and Nothing's, and they come from the phone and from
Qualcomm's open driver, so a Windows/WSL build needs no Mac for any of them.

| header | source |
| --- | --- |
| `mondrian_gmu_fw.h` | `gmu_gen70000.bin` from `/vendor/firmware` (or linux-firmware) |
| `mondrian_sqe_fw.h` | `a730_sqe.fw` from `/vendor/firmware` |
| `mondrian_zap_fw.h` | `a730_zap.mdt` + `.b01` (code) + `.b02` (signature) |
| `mondrian_cp_profile.h` | the CP tables of Qualcomm's open gen7 driver |

```sh
# the firmware: in recovery the stock vendor is a mapped logical volume
adb shell mount -t ext4 -o ro /dev/block/mapper/vendor_b /mnt/v
adb pull /mnt/v/firmware/a730_sqe.fw
adb pull /mnt/v/firmware/a730_zap.mdt
adb pull /mnt/v/firmware/a730_zap.b01
adb pull /mnt/v/firmware/a730_zap.b02
tools/gen-sqe-fw.py a730_sqe.fw  "$WORK/local/mondrian_sqe_fw.h"
tools/gen-zap-fw.py a730_zap.mdt a730_zap.b01 a730_zap.b02 \
    "$WORK/local/mondrian_zap_fw.h"

# the CP profile: the same four tables the vendor header has, taken from the
# open KGSL driver for this GPU (drivers/gpu/msm of NothingOSS's sm8475 tree)
tools/gen-cp-profile-open.py VENDOR_DIR "$WORK/local/mondrian_cp_profile.h"
```

`tools/wsl/build-kernel.sh` copies `$WORK/local/*.h` into the tree on every
build. Each missing header degrades silently, so check the ring: without the CP
profile the GPU does its full bring-up but logs `cp start without SQE firmware`
or publishes no `MondrianGPU` at all, and `mondrian-gl` falls back to the CPU
renderer.

## Boot time

The seven cores the ADT lists already start (`cpus=8` selects all of them; the
A510 at Aff1 0 stays parked with the firmware). The remaining cost is CPU
frequency and debug I/O:

- **`bootcpu`**: the loader starts the kernel on the X2 (physical core 7) and
  `boot_core=7` in `tools/boards.py` orders the ADT so it is logical cpu 0, so
  the `bootcpu` tunable is not needed. `cpufreq` is in (`0154`:
  1804/2496/2995 MHz on the three domains). The live SM8475 tree has
  `qcom,cpufreq-hw-epss` at **0x17d91000/0x17d92000/0x17d93000**,
  `qcom,lut-row-size=4`; HackiOS's own base is 0x18591000.
- **`IOAcceleratorES`**: topaz's 0138 (an empty `IOAcceleratorES`) saves ~30 s
  at every backboardd start; check what the mondrian's `0114` publishes.
- **Display refresh**: the topaz 0941-0949 add the vsync/presenter, direct
  frames and 60 Hz; today `mondrianfb_hz=60` (the panel itself is 120 Hz).
- **Canvas**: `mondrianfb_canvas_w/h` (default the panel) renders
  CoreAnimation into a smaller surface and scales it to the panel in `swap()`.
  The board does not set them: a 1125x2436 canvas is the iPhone X's 375x812 pt,
  but on this panel it makes text soft and the UI 7% oversized compared with
  drawing at the panel's own 1440x3200 (480x1066 pt, which is what iPhone 14 Pro
  Max-class apps expect). The scaled copy walks a column map built once,
  four pixels per 16-byte write (`0268`), and the fps line reports `clean avg`
  and `scale avg` so the next change has a number to aim at (`0269`); the
  earlier DDA versions measured 9-13 ms of scale a swap plus 18-31 ms for the
  memcpy-cached one (see the icon section). The 32/25 block is nearest
  neighbour, so text and icon edges come out jagged; the DPU SSPP scaler is the
  candidate fix and is not written.
  Use `mondrianreset=150`: a 45 s reset cuts the boot before the first swap.
  The CP tests hard-reset a non-journaled HFS; after several resets the next
  mount can take longer than 60 s (the ring stops at the UFS GPT with one
  process), so use 300 s or run `fsck_hfs` on the root image.
- **Modern `iig` (Xcode 16+)**: it emits `IORPC.kernelContent`, which xnu-8796
  does not have, so a build that reruns it dies in `DriverKit/*.iig.cpp` while
  the kernel objects are fine. `tools/build-kernel-local.sh` seeds both
  `iokit/DriverKit` and `iokit/<CONFIG>/DriverKit` from the other variant's
  generated stubs after the checkout reset, so the kernel relinks without the
  SDK `iig`; if neither variant has stubs yet, use the pregenerated ones
  HackiOS ships in `xnu-deps/`. A `make install` that fails in `config_all`
  after the link still leaves a usable `kernel.<config>.mondrian`.
- **Debug I/O**: `serial=0`, no `debug=0xc`, no `-enable_kprintf_spam` for
  normal boots; the `FB: swap`/HID/sampler logs go to the ring.
- **First boot**: a freshly flashed data volume needs one long first boot to
  create the containers and the `mobileactivationd` data ark; later boots reach
  the lock screen. Do not reflash to change a dylib: update it in place.
- **GPU**: the CoreAnimation GLES path is `mondrian-gl` over Mesa `libOSMesa`;
  `GL_RENDERER` reads `FD725`, so freedreno rasterises on the Adreno and OSMesa
  copies the result into the CPU-side surface; a GL flush costs 10-12 ms on
  some frames (`docs/UI_PERFORMANCE.md`).

## Milestones

Done: GPU memory, command submission and the Mesa `FD725` context; the
command-mode panel is kicked from the kernel at 60 fps, and the lock screen and
the home screen draw -- 59.9 fps over 180 s with no frame held (`mondriananim=1`).

Open: the jagged 1125x2436 -> 1440x3200 upscale (the DPU SSPP scaler is the
candidate), the idle-timer sleep (the hook's fix is not boot-verified), the
live wallpaper poster (the hook's still image draws), the panel's report rate
(`0xC0`), `cpufreq`, the release kernel and the boot-time measurements.
