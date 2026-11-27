# Audio on mondrian

The ADSP is up through PAS1. `mondrianadsp=1` starts a worker that reads the
joined `/private/var/vm/adsp.mbn` (`tools/adsp-image.py` joins the stock
`adsp.mdt` and `adsp.bNN`), maps the APPS-ADSP windows, and calls PAS1:
`init_image`, `mem_setup`, the ELF segment copies and `auth_and_reset`.
Measured 2026-11-27: every call returns 0, and the ADSP's `slave-kernel`
SMP2P entry answers `0x6` (READY | HANDOVER, the donor's bits 1 and 2) two
milliseconds after the reset. The `master-kernel` outbound SMP2P item and its
LPASS doorbell go in before the load, because the ADSP looks for it at boot.

The QMP `load_state` vote and the RPMh `lcx`/`lmx` votes are **not** needed for
this step on mondrian: the ADSP answers with the AOSS mailbox still closed.
They stay the fallback for a service that needs the rails.

## GLINK and GPR

The worker then opens GLINK on the APPS-ADSP FIFOs (SMEM items 478/479, the
DSP's receive item 480) and registers the `adsp_apps` channel as initiator
with 16 512-byte intents. Measured 2026-11-27: the version handshake
completes, the channel comes up, and the GPR query `APM_GET_SPF_STATE` sent
from client port `0x2001` to APM port 1 is answered `APM_SPF_STATE` with
status 1, so the ADSP audio framework is ready. The first three queries
return a basic result with status 1 before the fourth succeeds; the probe
must retry, and the worker allows eight.

## The APM speaker graph

Patch 0503 ports the donor's AudioReach builders (`ShengAudioReach.c`,
BSD-2-Clause-Patent) into `mondrian_audioreach.c`: the subgraph, container,
module and parameter encoding, the speaker device graph and the answer parser.
Measured 2026-11-27: subgraph `0x4005` with the I2S sink (`0x0700100A`,
instance `0x6051`) opens, the tertiary MI2S endpoint takes 48 kHz 32-bit
stereo on SD0 with the internal word select, and the graph closes; each
answer is a basic result with status 0.

The graph ids are **client-owned** values in the public APM ranges, not board
resources; the hardware facts come from the live tree. `/soc/spf_core_platform/sound`
muxes the tertiary MI2S (`mi2s2_sck` gpio121, `mi2s2_ws` gpio123,
`mi2s2_data0` gpio122), and the two `aw882xx_smartpa` nodes (i2c bus 2,
addresses 0x34 and 0x35, reset gpios 1 and 3, irq gpios 88 and 63) share that
one data line as a stereo pair (`sound-channel` 0 and 1). `mi2s2_data1`
exists in the pinctrl but the active set does not use it.

## The playback path

Patch 0504 adds the playback stream graph (`0x4001`: shared-memory endpoint,
PCM decoder, converter, linked to the device graph's `0x6051`), the PCM and
shared-memory media formats, the native map, the buffer write and the
prepare/start/stop/close commands. Measured 2026-11-27: device open, speaker
config, stream open, stream config and shared-memory config all answer status
0. The map is refused with status 1 when the buffer lands above 4 GiB
(`pa=0x84a200000`), which is the trap below; the worker then stops and closes
only what it opened.

The worker allocates 16 KiB with `kmem_alloc_contig()`, maps it with the
donor's DSP address form (`physical | (1 << 32)`), prepares the device graph
and then the stream, starts both, sends one 10 ms period (480 frames of
32-bit stereo, a 1 kHz square) and logs the write-done address and status.
Only the graph half is proven: the allocation lands above 4 GiB
(`pa=0x84a200000`), the map's upper word stops being 1 and the map answers
status 1, so the write does not run. A buffer in an SMEM item was tried as a
low alternative and is not usable: with the PCM item added the RAM boot never
answered (12 attempts fell back to `boot_b`) while the same image with
`mondrianadsp=0` booted, so the DSP's audio DMA does not take the SMEM path
the GLINK FIFOs use. The apps-SMMU SID `0x1801`, as the donor installs it, is
the next milestone. The AW88261 amplifiers are not programmed either, so
nothing is audible.

## Traps

- **The map address is `physical | (1 << 32)`, and the upper word must be
  exactly 1.** A PCM buffer above 4 GiB (`pa=0x84a200000`) is refused with
  status 1 (measured 2026-11-27), and so is anything whose PA does not fit in
  the low word; the donor checks `(tagged >> 32) == 1` before it maps.
- **The PCM buffer cannot be an SMEM item.** This unit has no free DRAM page
  below 4 GiB (`kmem_alloc_contig()` finds 0, measured 2026-11-27), and SMEM is
  the obvious low memory, but a PCM item there makes the RAM boot die before
  USB answers: 12 attempts fell back to `boot_b`, while the same image with
  `mondrianadsp=0` reached SpringBoard. The DSP's audio DMA does not take the
  SMEM path the GLINK FIFOs use. A DDR buffer has to be translated into the
  DSP's 32-bit space by the apps-SMMU SID `0x1801`, which is what the donor's
  `ZizhanAudioDmaMap` installs; that is the remaining porting job.
- **Graph management answers are basic results.** `GRAPH_OPEN`, `SET_CFG`,
  `PREPARE`, `START`, `STOP` and `CLOSE` complete with
  `GPR_IBASIC_RSP_RESULT` (`0x02001005`, payload `{command, status}`), not with
  a `0x0200100X` response. The map is two answers: the basic result first and
  `MEM_MAP_DONE` (`0x02001001`, payload `{handle}`) after, so the waiter must
  match the token and the answer kind; treating the basic ACK as the handle
  loses the map.
- **The windows cannot come from `ml_io_map()`.** It allocates from the fixed
  8 MiB `io_submap` with `KMA_NOFAIL`: the 2 MiB SMEM map after 49 MiB of
  carveout chunks either panics the boot in `kmem_alloc` or wedges the worker
  there. Map SMEM and the MMIO windows with `ml_io_map_unmappable()` and the
  attributes `ml_io_map` used (`VM_WIMG_IO`), and the carveout in 2 MiB
  `VM_WIMG_WCOMB` chunks.
- **`pmap_find_phys()` returns a ppnum in `PAGE_SIZE` units** (16 KiB here),
  not a 4 KiB page number. Convert with `ptoa_64()`; `pn << 12` hands TZ a
  buffer 4x below the metadata and `init_image` fails with transport
  `0xffcffff6`.
- **Map in the worker, not in `mondrian_log_start`.** A fault in the premap
  kills the boot before USB answers and leaves no ring on disk, so the failure
  is silent. The worker starts after the probes and `adsp_log()` flushes after
  every line.
- The firmware must be pushed to `/private/var/vm/adsp.mbn`; the worker waits
  up to 60 s for it and logs every segment it copies.

## What is next

First the PCM buffer: program the apps-SMMU context for SID `0x1801` (the
donor's `PongAudio`/`ZizhanAudioDmaMap` with `ArmSmmu4K`) and map a DDR buffer
to a 32-bit DSP address, so the write and its completion can run. Then the
loudspeaker amplifier: the AW88261 pair on i2c bus 2 (addresses 0x34/0x35)
needs its reset sequence, the I2C register profile and the unmute, after which
the already-running I2S endpoint is audible. The WCD938x is a SoundWire codec
and needs the LPASS SWR master and its own probe; it is the headphone path, not
this one. The donor ladder and the register references are in
`docs/REFERENCE_PORTS.md`; the `master-kernel`/`slave-kernel` SMP2P names and
the ready bits come from the zizhan ADSP worker.
