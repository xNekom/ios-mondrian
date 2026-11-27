# Audio on mondrian

The ADSP is up through PAS1. `mondrianadsp=1` starts a worker that reads the
joined `/private/var/vm/adsp.mbn` (`tools/adsp-image.py` joins the stock
`adsp.mdt` and `adsp.bNN`), maps the APPS-ADSP windows, and calls PAS1:
`init_image`, `mem_setup`, the ELF segment copies and `auth_and_reset`.
Measured 2026-11-27: every call returns 0, and the ADSP's `slave-kernel`
SMP2P entry answers `0x6` (READY | HANDOVER, the donor's bits 1 and 2) two
milliseconds after the reset. The `master-kernel` outbound SMP2P item and its
LPASS doorbell go in before the load, because the ADSP looks for it at boot.

The standard `tools/boards.py` line has no `mondrianadsp` and only eight bytes
of headroom. The audio test boots with a trimmed override: drop `battfix=`,
`wlan.debug.generate-mac` and the `mondrianwifi*` arguments, add
`mondrianadsp=1`, and let `image.sh` stamp `mondriantime` (558 bytes). Without
the argument the image reaches SpringBoard and runs no ADSP worker.

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
0; the map and the write are the 0505 step below.

The worker allocates 16 KiB with `kmem_alloc_contig()`, maps it into the
ADSP's 32-bit space, prepares the device graph and then the stream, starts
both, sends one 10 ms period (480 frames of 32-bit stereo, a 1 kHz square) and
logs the write-done address and status.

Patch 0505 adds `mondrian_audio_smmu.c`. The live tree routes the ADSP audio
master through apps-SMMU stream `0x1801` (`qcom,msm-audio-ion`) and gives the
vendor's 0x10000000 IOVA pool, so the buffer stays a high DDR allocation and
the DSP only sees IOVA `0x10000000`. The context is the donor's native 4K
stage-1 profile (CBAR `0x1f300`, TCR `0x80803520`, TCR2 `0x38071`, MAIR
`0xff44`, SCTLR `0x27`, ASID `0x1801`); its leaf is Normal non-cacheable,
outer shareable, read/write, from the donor's `ArmSmmu4KLive.c` audio range.

Measured 2026-11-27: the context takes the top free bank (74, `cb=0xca000`)
and a free SMR slot, the APM map returns a nonzero handle, and the write
completes with `address=0x1_10000000 status=0`, so the DSP read the 16 KiB
period through the SMMU. The context FSR reads `0x400` (bit 10, outside the
donor's `0xc00001fe` fault mask) with GFSR 0, so it is not a translation
fault; the FAR/FSYNR are stale from the previous user of the bank. The context
stays enabled: the graphs close, and tearing it down while the DSP might
still hold a reference would turn a clean test into a fault.

A buffer in an SMEM item remains unusable: with the PCM item added the RAM
boot never answered (12 attempts fell back to `boot_b`) while the same image
with `mondrianadsp=0` booted, so the DSP's audio DMA does not take the SMEM
path the GLINK FIFOs use. The AW88261 amplifiers are not programmed yet, so
nothing is audible.

## Traps

- **The map address is `DDR tag | low 32 bits`, and the upper word must be
  exactly 1.** The low word is the address the DSP's DMA emits, not necessarily
  the physical address. A physical address above 4 GiB cannot be used directly:
  `pa=0x84a200000` was refused with status 1 (measured 2026-11-27). The vendor
  maps an IOVA from the audio-ion pool (`0x10000000`) through apps-SMMU SID
  `0x1801`; 0505 does the same, so the buffer can stay high.
- **The PCM buffer cannot be an SMEM item.** SMEM is low and contiguous, but a
  PCM item there makes the RAM boot die before USB answers: 12 attempts fell
  back to `boot_b`, while the same image with `mondrianadsp=0` reached
  SpringBoard. The DSP's audio DMA does not take the SMEM path the GLINK FIFOs
  use. The earlier "no free DRAM below 4 GiB" reading came from
  `kmem_alloc_contig(max_pnum=0x3ffff)`, which searches below 1 GiB; this SoC's
  DRAM starts at 2 GiB, so that call could never find a page. The IOVA path
  makes the search unnecessary.
- **The apps-SMMU is `qsmmu-v500` at `0x15000000` and its context banks are
  not at 0x1000.** IDR1 reports 75 banks and 128 global pages; bank n lives at
  `(128 + n) * 4 KiB` (bank 74 at `0xca000`), with SMR/S2CR at `0x800`/`0xc00`
  plus 4n. `mondrian_wifi_smmu.c` is the in-tree reference that measured this
  geometry on the unit.
- **The context FSR is not a boolean.** Bit 10 (`0x400`) is outside the
  donor's `0xc00001fe` fault mask; an FSR of `0x400` with FSC 0 and GFSR 0 is
  not a translation fault. The FAR/FSYNR are not cleared by the FSR
  write-one-to-clear, so they can describe an earlier user of the bank.
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

The PCM path is proven at the APM level. Next is the loudspeaker amplifier:
the AW88261 pair on i2c bus 2 (addresses 0x34/0x35) needs its reset sequence,
the I2C register profile and the unmute, after which the already-running I2S
endpoint is audible. The WCD938x is a SoundWire codec and needs the LPASS SWR
master and its own probe; it is the headphone path, not this one. The donor
ladder and the register references are in `docs/REFERENCE_PORTS.md`; the
`master-kernel`/`slave-kernel` SMP2P names and the ready bits come from the
zizhan ADSP worker.
