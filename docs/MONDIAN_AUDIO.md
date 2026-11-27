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
stereo with the internal word select, and the graph closes; each answer is a
basic result with status 0. Patch 0507 opens this subgraph and the playback
stream as one graph.

The graph ids are **client-owned** values in the public APM ranges, not board
resources; the hardware facts come from the live tree. Its active pad group is
`tert_tdm_pinctrl` (`status = "ok"`): sck gpio121, ws gpio123 and dout
**gpio124** (function `mi2s2_data1`), 8 mA with a pull-down on dout.
`tert_mi2s_pinctrl` with gpio122 (`mi2s2_data0`) is `status = "disabled"`;
gpio122 is the TDM din/capture line. `pinctrl-sm8450.c` puts `mi2s2_data1` at
register mux value 1 on gpio124. The two `aw882xx_smartpa` nodes (i2c bus 2,
0x34 and 0x35, reset gpios 1 and 3, irq gpios 88 and 63) are
`sound-channel` 0 and 1 on that one dout line.

## The playback path

Patch 0504 adds the playback stream subgraph (`0x4001`: shared-memory
endpoint, PCM decoder, converter, linked to the device graph's `0x6051`), the
PCM and shared-memory media formats, the native map, the buffer write and the
prepare/start/stop/close commands. Measured 2026-11-27: the graph open, the
speaker config, the stream config and the shared-memory config all answer
status 0; the map and the write are the 0505 step below.

Patch 0507 feeds the sink from the shared-memory endpoint through the donor's
chain (`WR_SHARED_MEM_EP -> PCM decoder -> PCM converter`). The sink is the
AudioReach TDM module (`0x0700100E`) on the tertiary interface, lane 1
(`0x0800106A` mask 2, gpio124), with one BCLK of data delay. The device graph
holds only the endpoint; the stream graph's last connection names it, and both
graphs are open before the link is resolved. `PREPARE`, `START`, `STOP` and
`CLOSE` go out once per subgraph: a command carrying both ids is accepted, so
a list that only applied its first entry would leave the endpoint clocking
while the stream idles. The I2S module (`0x0700100A`, SD1) also clocked the
pads but never drove data1.

The worker allocates eight periods (30720 bytes, a whole number of 3840-byte
periods) with `kmem_alloc_contig()`, maps the ring into the ADSP's 32-bit
space, prepares and starts both subgraphs, then queues every slot with its own
offset. The endpoint renders only from a lead of queued periods: a 16 KiB
ring is not a whole number of periods, and one write after the start is
consumed before the sink starts. It logs each write-done address and status,
reads SYSST after the ring is queued, and samples the SCK, WS, DATA1 and
spksw pads through their TLMM input bits.

Patch 0505 adds `mondrian_audio_smmu.c`. The live tree routes the ADSP audio
master through apps-SMMU stream `0x1801` (`qcom,msm-audio-ion`) and gives the
vendor's 0x10000000 IOVA pool, so the buffer stays a high DDR allocation and
the DSP only sees IOVA `0x10000000`. The context is the donor's native 4K
stage-1 profile (CBAR `0x1f300`, TCR `0x80803520`, TCR2 `0x38071`, MAIR
`0xff44`, SCTLR `0x27`, ASID `0x1801`); its leaf is Normal non-cacheable,
outer shareable, read/write, from the donor's `ArmSmmu4KLive.c` audio range.

Measured 2026-11-27: the context takes the top free bank (74, `cb=0xca000`)
and a free SMR slot, the APM map returns a nonzero handle, and the write
completes with `address=0x1_10000000 status=0`, so the DSP read the mapped
buffer through the SMMU. The context FSR reads `0x400` (bit 10, outside the
donor's `0xc00001fe` fault mask) with GFSR 0, so it is not a translation
fault; the FAR/FSYNR are stale from the previous user of the bank. The context
stays enabled: the graphs close, and tearing it down while the DSP might
still hold a reference would turn a clean test into a fault.

A buffer in an SMEM item remains unusable: with the PCM item added the RAM
boot never answered (12 attempts fell back to `boot_b`) while the same image
with `mondrianadsp=0` booted, so the DSP's audio DMA does not take the SMEM
path the GLINK FIFOs use.

Patch 0506 programs the AW88261 pair over bit-banged I2C: fuses, soft reset,
the stock `aw882xx_acf.bin` Music profile, the fuse-derived `0x50`
calibration, the parked mute state and the data1 pad function (gpio124). The
worker waits for the prepare, clears power-down, waits for the PLL, enables the
power stage, releases both mutes at the profile volume and powers the pair down
after the periods. Measured 2026-11-27: both parts answer `0x2113`, both
57-register profiles read back (`0x04=0x73c3`, `0x08=0x00f6/0x00f7`), the
fuses gave icalk 992/1001 against vcalk 992/994, both PLLs lock to the bit
clock (`SYSST 0x0011`), and the PCM write completes with status 0. VBAT reads
3598 mV and PVDD tracks it.

The pads answer for themselves, but the first sampler watched the wrong one.
It read DATA0 (gpio122), the disabled `tert_mi2s` group's line, and measured
0.05-0.45 % high with hundreds of edges while the pair sat on gpio124. The
live tree's active `tert_tdm_pinctrl` muxes sck gpio121, ws gpio123 and dout
gpio124 (`mi2s2_data1`); gpio122 is the TDM din/capture line. The sampler and
the sink now use data1. Opening both subgraphs in one `GRAPH_OPEN` was
accepted with status 0 on every command, and the direct shmem -> I2S link was
accepted too, both still reading data0; the decoder/converter chain was not
the silence. The one-LSB sign square (`0x00000001`/`0xffffffff`) makes the
fill visible at any width and stays inaudible.

## Traps

- **The speaker data line is data1/gpio124, not data0/gpio122.** The live
  tree's active `tert_tdm_pinctrl` (`status = "ok"`) is sck gpio121, ws gpio123
  and dout gpio124 (`mi2s2_data1`), 8 mA with a pull-down on dout. The
  `tert_mi2s_pinctrl` block with gpio122 (`mi2s2_data0`) is `status =
  "disabled"`; gpio122 is the TDM din/capture line. `pinctrl-sm8450.c` maps
  register mux value 1 to `mi2s2_data1` on gpio124, so the raw TLMM write is
  `(1 << 2) | pull | (drive << 6) | (1 << 9)`. Sampling gpio122 explains the
  0.45 % with hundreds of edges: it is a line the pair never sees. Both
  `aw882xx_smartpa` nodes are `sound-channel` 0 and 1 on the single dout line.
- **The map address is `DDR tag | low 32 bits`, and the upper word must be
  exactly 1.** The low word is the address the DSP's DMA emits, not necessarily
  the physical address. A physical address above 4 GiB cannot be used directly:
  `pa=0x84a200000` was refused with status 1 (measured 2026-11-27). The vendor
  maps an IOVA from the audio-ion pool (`0x10000000`) through apps-SMMU SID
  `0x1801`; 0505 does the same, so the buffer can stay high. The donor builds
  the same tag (`dmaPa | (1ull << 32)`) and masks the write completion address
  with `0xffffffff`; our map and write payloads match
  `APM_CMD_SHARED_MEM_MAP_REGIONS` and
  `DATA_CMD_WR_SH_MEM_EP_DATA_BUFFER_V2` field for field.
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
- **A connection to a module in another open is accepted; it is not the audio
  blocker.** The donor's stream graph lists the converter-to-I2S link while the
  sink lives in the device graph, and the APM answers status 0. Opening both
  subgraphs in one `GRAPH_OPEN` also returns status 0 and left DATA0 at 0.45 %
  (measured 2026-11-27). Build the list once for clarity, but a split open does
  not explain silence.
- **A builder that overflows `GPR_MAX_PACKET` returns zero without a word.**
  The two-subgraph `GRAPH_OPEN` is about 560 bytes; with the old 512-byte
  ceiling the worker left right after the SPF query with no APM line at all.
  The ceiling is 1024 now, and the graph-open caller logs a zero length. Any
  new builder that can grow must be measured against the ceiling and must log
  when it does not fit.
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
- **A pin muxed to a peripheral function needs its TLMM output enable.** The
  MI2S2 mux set OE for SCK and WS but left it clear on GPIO122, so
  `mi2s2_data0` selected the I2S function with the pad tri-stated. The pair
  locked its PLL to the running bit clock and reported `SYSST 0x0011` for
  80 ms of periods with SWS/BSTS never set, because it was decoding a silent
  line. `mondrian_tlmm_cfg()`'s last argument is the pad output enable, not a
  spare; the three MI2S2 pins are all outputs from the SoC's side. After the
  fix SCK and WS read 50 % high while DATA0 still read 0.05 %, so data that
  only occupies high bits is not proof: the sampler has to see the actual
  sample pattern.
- **SWS/BSTS are not a usable ready gate.** Upstream `aw88261` stopped
  requiring them in 2026 ("check sysst fail, reg_val=0x0011"): a part that is
  still muted legitimately reports only PLLS|CLKS. Require PLLS and CLKS
  before the mute release and treat SWS/BSTS as information.
- The firmware must be pushed to `/private/var/vm/adsp.mbn`; the worker waits
  up to 60 s for it and logs every segment it copies.

## What is next

The one-graph open is the open measurement: with the sink connected, DATA0
must answer the one-LSB sign square at roughly 50 % high (it was 0.45 % with
the split graph) and the amplifier should then have real samples. If DATA0
moves but SWS/BSTS stay 0, the bits are informational and the next step is an
audible-level pattern at the observed width. If DATA0 stays silent, the next
suspect is the per-module format negotiation, not the amplifier.

After that, audible output from the userland needs the virtual audio HAL wired
to this graph instead of the one-shot probe. The WCD938x is a SoundWire codec
and needs the LPASS SWR master and its own probe; it is the headphone path, not
this one. The donor ladder and the register references are in
`docs/REFERENCE_PORTS.md`; the `master-kernel`/`slave-kernel` SMP2P names and
the ready bits come from the zizhan ADSP worker.
