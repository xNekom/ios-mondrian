# Audio on mondrian

The speaker path is proven end to end: the ADSP graph drives the AW88261 pair
on the live TDM line and the pair plays a 1 kHz tone (measured 2026-11-27, heard
on the speaker). Everything below is how that path is built, what each stage
needs and which measurements it answers to.

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
`tert_tdm_pinctrl` (`status = "ok"`): sck gpio121, ws gpio123, din gpio122
(function `mi2s2_data0`) and dout gpio124 (function `mi2s2_data1`), 8 mA with
a pull-down on the data pads. Those names are the *codec's* directions, not
the AP's: the pair hears the line the AP drives, which is gpio122 - the live
`tdm_tert_tx` node asks for `qcom,msm-cpudai-tdm-data-out = 0`.
`pinctrl-sm8450.c` puts both data functions at register mux value 1. The two
`aw882xx_smartpa` nodes (i2c bus 2, 0x34 and 0x35, reset gpios 1 and 3, irq
gpios 88 and 63) are `sound-channel` 0 and 1 on that one data line.

## The playback path

Patch 0504 adds the playback stream subgraph (`0x4001`: shared-memory
endpoint, PCM decoder, converter, linked to the device graph's `0x6051`), the
PCM and shared-memory media formats, the native map, the buffer write and the
prepare/start/stop/close commands. Measured 2026-11-27: the graph open, the
speaker config, the stream config and the shared-memory config all answer
status 0; the map and the write are the 0505 step below.

Patch 0507 feeds the sink from the shared-memory endpoint through the donor's
chain (`WR_SHARED_MEM_EP -> PCM decoder -> PCM converter`). The sink is the
AudioReach TDM module (`0x0700100E`) on the tertiary interface, configured as
**four slots of 32 bits** with `slot_mask 3` (the two channels), lane mask 2
(`0x0800106A`), a one-slot sync pulse (`sync_mode 2`, not inverted) and one
BCLK of data delay. The device graph holds only the endpoint; the stream
graph's last connection names it, and both graphs are open before the link is
resolved. `PREPARE`, `START`, `STOP` and `CLOSE` go out once per subgraph: a
command carrying both ids is accepted, so a list that only applied its first
entry would leave the endpoint clocking while the stream idles.

Measured 2026-11-27: with a **two-slot** frame every command answered status 0
and SCK/WS ran at 50 % while no data pad moved, so an accepted graph is not
evidence of a data path. At four slots the sink drives DATA0 and the pair plays
- a 1 kHz square at -6 dBFS is loud enough to startle, which is the milestone
- and the same boot reports `SYSST 0x0311` (class-D switching) with the boost
up, against `0x0011` before.

The worker allocates eight periods (30720 bytes, a whole number of 3840-byte
periods) with `kmem_alloc_contig()`, maps the ring into the ADSP's 32-bit
space, prepares and starts both subgraphs, then queues slots with their own
offsets. The endpoint renders only from a lead of queued periods: a 16 KiB ring
is not a whole number of periods, and one write after the start is consumed
before the sink starts. It writes one silent pass first and then twelve passes
of a gated 150 ms beep, rewriting a slot only after the endpoint has answered
for all eight periods. It logs each write-done address and status, reads SYSST
after the ring is queued, and samples the SCK, WS, both data pads and spksw
through their TLMM input bits after a GPIO self-test of each pad.

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
calibration, the parked mute state and both mi2s2 data pads (gpio122 and
gpio124, function 1, with a pull-down). The worker waits for the prepare,
clears power-down, waits for the PLL, enables the power stage, releases both
mutes at the profile volume and powers the pair down after the periods.
Measured 2026-11-27: both parts answer `0x2113`, both 57-register profiles read
back (`0x04=0x73c3`, `0x08=0x00f6/0x00f7`), the fuses gave icalk 992/1001
against vcalk 992/994, both PLLs lock to the bit clock, and the PCM write
completes with status 0. Once the frame is four slots wide the pair reports
`SYSST 0x0311` (class-D switching) and the boost comes up; before that it stays
at `0x0011`.

The pads answer for themselves, and the instrument proves itself too: with
each pin temporarily muxed as a plain GPIO and driven low then high, sck, ws,
data0 and data1 all read 0 then 1. Measured 2026-11-27 with that check in
place: with a **two-slot** frame SCK and WS run at 50 % and neither data line
moves, while with a **four-slot** frame the sink drives DATA0 (gpio122) at
once. The high share of the pad follows the slots that carry samples - about
13 % of the frame with one slot filled and about 25 % with the converter
sending both channels interleaved - and both amplifiers go from `SYSST 0x0011`
to `0x0311` (class-D switching) with the boost up. The frame width was the
gate, and the stock ACF explains why: it runs the pair in four-slot TDM
(`SLOT_NUM = TDM4S` in `I2SCTRL2` 0x07 bits 14:12, `I2SFS` 32 bits, `I2SBCK`
64 fs), and the vendor driver never rewrites those registers, so four slots is
what the phone's amplifier actually runs.

## Traps

- **The speaker pair listens on data0/gpio122; the pinctrl names are the
  codec's.** `qcom,msm-cpudai-tdm-data-out = <0>` on the live `tdm_tert_tx`
  node picks data line 0, and that is the line the DSP drives: with a
  four-slot frame gpio122 (`mi2s2_data0`) carries the samples (12.6 % high,
  48 k frames/s) while gpio124 (`mi2s2_data1`) stays flat. Read
  `tert_tdm_din` (gpio122) and `tert_tdm_dout` (gpio124) as the *codec's*
  directions, not the AP's: the amplifier pair hears the line the AP drives.
  `tert_tdm_pinctrl` is `status = "ok"` and muxes clk gpio121, ws gpio123,
  din gpio122 and dout gpio124; `pinctrl-sm8450.c` maps register mux value 1
  to both data functions, so the raw TLMM write is
  `(1 << 2) | pull | (drive << 6) | (1 << 9)` for either pad. Both
  `aw882xx_smartpa` nodes are `sound-channel` 0 and 1 with `sync-flag = 1`,
  and their stock profile gives the left part slot 1 and the right part
  slot 0.
- **A two-slot frame is accepted and never drives a data line.** With
  `nslots_per_frame 2` every command still answers status 0, SCK and WS run at
  50 %, the amplifiers lock their PLL - and no data pad moves. Only
  `nslots_per_frame 4` starts the sink driving DATA0 (measured 2026-11-27).
  A graph that "runs" is therefore not evidence of a data path; check a data
  pad, not just the clocks.
- **The codec, not the pad, says whether frames arrive.** `I2SINT` (0x26)
  reads `0x0005` with the bit clock running and no buffer queued, and drops to
  `0x0000` as soon as one period is written, so it is the quickest witness that
  the serializer is receiving framed data. `I2SCAPCNT` (0x27) sits saturated
  at `0x1fff` either way. `ISNDAT` (0x24) and `VSNDAT` (0x25) read about zero
  even while the pair switches and the tone is audible, because the stock ACF
  leaves the sense path off: they cannot witness the analog side, and neither
  can `SYSST` alone - a part that renders and a part that only runs its
  modulator both report `0x0311`.
- **The pad sampler resolves 48 kHz, not the bit clock.** Each loop iteration
  reads five TLMM pages and runs at about 0.7 M samples/s (measured 2026-11-27:
  315566 reads over the window), so counting SCK edges per WS period returns
  nonsense (6 "bits per frame"). The WS *frequency* and the high-time *ratios*
  are trustworthy; a bit count is not.
- **Tell the two data-out enables apart before blaming either.** The TDM
  interface parameter (`0x0800101B`) is, in order, `lpaif_type`, `intf_idx`,
  `sync_src`, `ctrl_data_out_enable`, `slot_mask`, `nslots_per_frame`,
  `slot_width`, `sync_mode`, `ctrl_invert_sync_pulse`,
  `ctrl_sync_data_delay`, `reserved`; the live `tdm_tert_tx` node asks for
  `data-out 0`, internal sync, long sync, an inverted pulse and one BCLK of
  delay, which is what 0507 sends. Value 1 means "share data-out with other
  masters" and 0 means this block owns the line, and the pads read flat with
  both. The TLMM `GPIO_IN_OUT` bit 1 is a GPIO-function bit: a pad muxed to
  `mi2s2` ignores it (flat with both values), which is why the GPIO self-test,
  not a register readback, is the only way to trust a pad measurement.
- **The map address is `DDR tag | low 32 bits`, and the upper word must be
  exactly 1.** The low word is the address the DSP's DMA emits, not necessarily
  the physical address. A physical address above 4 GiB cannot be used directly:
  `pa=0x84a200000` was refused with status 1 (measured 2026-11-27). The vendor
  maps an IOVA from the audio-ion pool (`0x10000000`) through apps-SMMU SID
  `0x1801`; 0505 does the same, so the buffer can stay high. The upper word is
  the stream id, as mainline builds it (`phys_addr | (pdata->sid << 32)`, with
  `sid` the low nibble of the `iommus` phandle argument, so `0x1801` becomes
  1). The donor builds the same tag (`dmaPa | (1ull << 32)`) and masks the write
  completion address with `0xffffffff`; our map and write payloads match
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
- **A pad muxed to a peripheral function takes its direction from the block,
  not from the GPIO output-enable bit.** The MI2S2 mux sets the TLMM
  `GPIO_IN_OUT` bit for SCK and WS; the same bit on the data pads changed
  nothing (DATA1 read flat with it clear and set: 0.4 %, about 90 noise edges
  either way). What decides whether the data pads carry a frame is the
  AudioReach endpoint's own configuration - the four-slot frame is the one that
  drives them (measured 2026-11-27) - so a flat data pad with running clocks
  means the endpoint is not transmitting, not that the pad is tri-stated.
- **SWS/BSTS are not a usable ready gate.** Upstream `aw88261` stopped
  requiring them in 2026 ("check sysst fail, reg_val=0x0011"): a part that is
  still muted legitimately reports only PLLS|CLKS. Require PLLS and CLKS
  before the mute release and treat SWS/BSTS as information.
- The firmware must be pushed to `/private/var/vm/adsp.mbn`; the worker waits
  up to 60 s for it and logs every segment it copies.
- **A restarted `mediaserverd` segfaults, and the dead audio server freezes the
  whole UI.** Measured 2026-11-27: after `killname mediaserverd`, every fresh
  instance dies at startup in CoreFoundation (`pc` `CoreFoundation+0x7ab64`,
  `far 0`, `sig 11`, unslid the same on every boot) and launchd respawns it
  every 5 s. SpringBoard's main thread then waits on the audio server, its
  runloop stops ticking (`MONDRIAN UI: ca ... loop 0 in 1 s`, the hook's own
  `lock step stuck; reposting`) and the panel keeps the last frame: the screen
  looks frozen while the kernel and the ring are fine. Do not restart the daemon
  to reload a HAL plug-in - it is scanned at boot, so a plug-in change is a
  reboot. `tools/dsc-va.py CACHE --slide 0x... ADDR` plus `tools/dsc-sym.py`
  name the frames (`HALS_System::DeviceManagerCreated` -> a CoreFoundation
  string compare reaches a NULL). The crash survives removing every plug-in
  (`/System/Library/Audio/Plug-Ins/HAL` empty, no `VirtualAudio`), deleting the
  CoreAudio preferences and the Bluetooth transport, so it is the root volume,
  not a device: reflashing `backup/ios-root.simg` is the repair.

- **`VirtualAudio` crashes `mediaserverd` on this port, with or without our HAL.**
  Measured 2026-11-27 on a freshly flashed root: loading it from
  `/Library/Audio/Plug-Ins/HAL` gives `crash=20`, five respawns and a frozen UI
  (`loop 0`); without it `crash=0`. Its bundle is complete and its
  `CFBundleIdentifier` is present, so the NULL belongs to a device manager
  Apple creates without a bundle-id. REA/Rizin on `VirtualAudio` (Mach-O arm64)
  and on the reconstructed `CoreAudio.va` shows the `cbz x0` that leaves the
  string NULL before the `objc_msgSend`. This is why `tools/ios-root-tweaks.py`
  moves the plug-in to `HAL.disabled`: do not re-enable it for routing. Copying
  it back with `wfile` also re-damages the HFS volume, so a reflash is needed
  to recover.
- **The SMMU driver allowed only one PCM buffer.** With `mondrianadsp=1` the
  boot worker mapped the buffer once; a HAL client's second run allocated a
  different VA and `mondrian_audio_smmu_map()` refused it (`one buffer already
  mapped`), tearing down the graph. Patch `0510` releases the old translation
  before installing the new one. Put local source changes in a patch under
  `xnu/patches-mondrian/` before a build: `build-kernel.sh` resets the tree
  from the series and silently compiles the old source otherwise.

## What is next

The kernel side is complete: the ADSP graph starts with `status=0`, the HAL
loads and opens `/dev/mondrian-audio` (`opened=1`), and the SMMU map no longer
fails. The remaining gap is userland routing: **iOS never writes samples**
(`audio node: PCM` stays 0 when a tone is played). `VirtualAudio.plugin` is the
routing layer that would select our `Speaker`, but it crashes mediaserverd here
and the root tweak disables it. Work out a route to the HAL device that does
not depend on that plug-in - either make `Speaker` the default output from our
own plug-in, or fix the NULL bundle-id in CoreAudio's device manager. Keep
`mondrianadsp=1` for every audio boot.

The WCD938x is the headphone and mic path: a SoundWire codec that needs the
LPASS SWR master and its own probe. The donor ladder and the register
references are in `docs/REFERENCE_PORTS.md`; the `master-kernel`/`slave-kernel`
SMP2P names and the ready bits come from the zizhan ADSP worker.
