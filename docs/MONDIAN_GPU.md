# GPU and boot time

The UI renders through the GPU: the draw completes, the frame is drawn in
place (no readback, no copy) and the display swaps it 57-64 times in a second,
against the 60 Hz the panel and the iPhone X mode run at. The wall is pacing — a
frame reaches the display 8 ms after the vsync it was meant for — not
rasterisation. The other ios-sweet ports render through
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
- **The switch is a no-op that parks.** Plain: `CP_SET_SECURE_MODE(0)` (ring
  dword 10, header `0x70e60001`) never retires (`cp secmode rptr 11 wptr 12`,
  SQE parked at ucode PC 0x649, `fault 0`, `int 0x80`), nothing after it runs,
  and neither a full power cycle nor the retry that puts a `CP_NOP` over the
  stalled dword changes it. The reason is in the read-back: after a successful
  ZAP the CP is **already nonsecure** (`cp notready secure 0x0`, `trust 0x1`,
  `sqebase 0x100000`), so its `setsecure` has nothing to switch and parks.
  `cpnosecmode=1` skips the packet; the next one, `CP_MEM_WRITE`, then
  executes and its canary lands.
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
- **The ring is closed with a `CP_NOP` when it wraps.** The CP fetches from
  the read pointer towards the write pointer, so a write pointer that jumps
  back to zero leaves it fetching dwords nobody wrote (the ring starts zeroed,
  so they decode as type-0 register writes). Fill the tail with one
  `CP_NOP` covering it, publish the wrap, and wait for `CP_RB_RPTR` to read 0
  before writing at the start. Measured with 2000 back-to-back submissions:
  183 refused before the fix, 0 after it, with the last canary and fence
  exactly the ones the last submission asked for.
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
- **The next thing to measure is the pipeline state as a matrix**, because the
  self test turns each knob into a yes/no: `glselftest=1` with the default
  (GMEM, `A7XX_RB_UNKNOWN_8812(0x3ff)` "all buffers in sysmem"), with
  `glenv=FD_MESA_DEBUG=sysmem` and with `gmem` forced, and the same three with
  `glcopy=1` so the readback does not depend on the surface import. A green draw
  in any cell names the state that is wrong; all-black with the submissions
  completing points at the shader/state upload (`CP_LOAD_STATE6`,
  `CP_IM_LOAD`) or at a render-target address the RB never sees.
- **The SP warm-up kernel: the last unfilled piece of the pipeline, and it
  belongs in Mesa's stream.** Mesa 25.0.7 has the a725/a730 `cmdbuf_start_a725_quirk`
  in Turnip's path (`tu_init_cmdbuf_start_a725_quirk`: a multiply over the whole
  shader array, 12 groups of 255 waves, the register writes that aim it, and
  `CP_EXEC_CS`, whose comment says "It is unknown what this workaround is for
  and what it fixes") — the GL build does not, and on this BringUp's a730 with
  vendor 01730158 firmware, the pipeline draws nothing to memory without it:
  `0229` builds the same stream in the kernel and emits it at the start of a
  submission with `cpuirk=1`. When the ring flashes it, the submission that
  carries it consumes and parks (`uc big 253 dwords fence 1 done 0`), so the
  kernel cannot wrap it around a whole client IB — its invalidations eat the
  batch's own state loads. The bisect to run next is emit-side: build the
  warm-up stream in the GL library and emit it at the start of every
  `fd6_emit_restore` for `CHIP >= A7XX`, with the kernel knob off, exactly
  where Turnip puts it inside its command buffers. The bootstrap handshake is
  not the gap: `l162` in the SQE (`brne $02, 0x0, #l162`, right after
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
  `316 GL calls, 44 draws, 228 triangles`. The wallpaper and some text are still
  white blocks because a texture upload fails (`glDrawElements: 0x502`
  eighteen times and `glTexImage2D: 0x505` in one boot; `0x502` is
  `GL_INVALID_OPERATION`, `0x505` is `GL_OUT_OF_MEMORY`). Do not read the
  picture as a geometry or a GPU bug.
- **Installing the userland into the root image is one pass.** Mesa's
  `libOSMesa.8.dylib` goes to `/usr/lib` (its install name), the UI hook and
  the GPU test to `/usr/libexec`:
  `sudo tools/install-userland.sh IMAGE --ui-hook HOOK --gpu-test TEST
  --mesa out/mesa/stage`, then `tools/mk-simg.py` and
  `tools/flash-root.sh`. The kernel only injects the UI hook
  (`mondrian_ui_hook`), so everything else hangs off it.
- **The GPU presents the UI at 57-64 swaps a second, and pacing is what is
  left.** A lock-screen frame is 96-350 GL calls, 11-51 draws and 36-320
  triangles drawn in place (`0 pictures copied out`), 2.9-3.8 ms of which is
  handing the commands on and ~2-4.7 ms waiting; the display swaps up to 64
  times in a second while the screen is touched (`touch 17/s`) and 57 on the
  lock screen before it settles, and the sampler reports frames arriving 8 ms
  *after* the vsync they were meant for (`late avg 8176 us`), so the panel shows
  each one a refresh late instead of on time. Three measured costs:
  `frame_end()` calls `glFinish()` once per frame because `display_waits()`
  reports that the display driver does not wait for the submission that named the
  surface (`tools/gpu/eagl.c`, `glwait=`), which serialises the CPU behind the
  GPU; CoreAnimation draws only when something changes, so a still screen swaps
  1-4 times a second; and SpringBoard spends its sampling window in the
  forced-activation poll (`SBSetupManager sharedInstance, reason forced 0` every
  two seconds), which is where its 256-deep sample comes from. A fence the
  compositor can wait on at present time is the first one to remove.
  The firmware blocks, the GMU context bank and the CM3 start are in
  `mondrian_gpu.c` under `gmustart=1`.

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

The eight cores already start (`cpus=8`, all `PSCI CPU_ON rc=0`). The remaining
cost is CPU frequency, the boot CPU and debug I/O:

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
  `swap()`. It was a way around the CPU rasterizer (900x2000 measured 9.3 fps
  against 6.4 at the full panel) and the CPU scale in `swap()` costs 30-40 ms a
  swap, so do not use it to chase frame rate now that the GPU draws. Use
  `mondrianreset=150`: a 45 s reset cuts the boot before the first swap.
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
- **GPU**: CoreAnimation draws on the GPU (see "Milestones"); the CPU renderer
  is the fallback when `MondrianGPU` is absent (`gpu=0`).

## Milestones

Done: GPU memory, command submission and the Mesa `FD725` context; CoreAnimation
GLES drawn by the GPU with the no-copy IOSurface presenter, 57 swaps a second.
Open: paced presentation (frames land 8 ms after their vsync), `bootcpu`/
`cpufreq`, the release kernel and the boot-time measurements.
