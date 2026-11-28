# WiFi and Bluetooth on mondrian

Wi-Fi does not work yet. Bluetooth does: iOS's own `bluetoothd` drives the
QCA6490's BT half over the QUP UART, and this port supplies the HCI transport,
the firmware load and the vendor-command translations (the measured state is
below). The kernel exports no `IO80211`, `IOBluetooth`,
`IOEthernet` or `IOSerial` symbol (measured with `nm`); Wi-Fi still needs the
PCIe, MHI, QMI and `ath11k` bring-up. The phone carries a Qualcomm **QCA6490**
combo, whose two halves are separate buses and separate projects.

`0415` adds the first Wi-Fi milestone behind `mondrianwifi=1`: PCIe0 cold link
and QCA6490 config identity only, with bus mastering off and no SMMU, DMA, MSI,
MHI or firmware. Measured 2026-11-25 with Bluetooth off: all eight WLAN/PCIe
rails voted, the live 82-entry PHY table loaded, link
came up **Gen2 x1**, and config read `17cb:1103`, subsystem `17cb:0108`,
revision `01`; bus mastering read back clear. The worker reuses touch's early
GCC window because a second late `ml_io_map()` of the same block stalled. The default
boot (no `mondrianwifi`) emits no Wi‑Fi worker lines and `btuart` still reads the
Bluetooth controller identity.

`0417`/`0418` add W2 under the same gate: guarded apps-SMMU access, one wired
canary, and readback of the SID `0x1c01` route. Measured 2026-11-25:
`IDR0=0x4c017e71`, `IDR1=0x6000004b`, `IDR2=0x5111` give native
4K, 32-bit input, 36-bit output, 75 context banks and 120 SMR slots. The
inherited `sCR0=0x280406` is preserved. Bank 74 programs `SCTLR=0x27` and
`TTBR0=0x1c01000849ff0000`; slot 6 reads back `SMR=0x80001c01`, `S2CR=0x4a`.
Bus mastering stays off and teardown completes. `ATOSNS=1` means `ATS1PR` is
absent, so the result is **W2 PARTIAL**: context/route proof, not a hardware
page walk or endpoint DMA.

`0422` adds W3 under the same gate. It fixes the PCI command mask: bit 1 is
memory space and bit 2 is bus master, so W1 had been disabling memory and never
touching DMA. Measured 2026-11-25: the bootloader leaves BAR0 at
`0x00000004/0x00000000` (address 0); writing `0x60200004` with memory off reads
back `0x60200004`, and the bus-master bit sets (`command=0x0006`) and clears
(`0x0002`). The first attempt also mapped the BAR and hung on the first read, so
the MHI registers wait for the guarded accessor; no ring, DMA, MSI, firmware or
network is started.

`0423` reads the MHI block through a one-page BAR map. A 2 MiB `ml_io_map()`
stalled the worker; one page holds MHI and BHI. Measured 2026-11-25:
`MHIVER=0xdeadbeef`, `MHICFG=0x800080`, `MHISTATUS=0x0`, `BHIOFF=0x100`,
`BHIEOFF=0x224`; the guarded read completes, so the BAR decodes.

`0424` reads the BHI block at `BHIOFF=0x100`. Measured 2026-11-25:
`BHI ver=0x1.2`, `status=0x0` (reset), `execenv=0x0` (PBL), `serial=0x907d3a8b`,
`anti=0x0`, `segs=1`, `hwid=0x1016d0e1`. The device is in the bootloader and
ready for a BHI image; the next step is a DMA-mapped `amss.bin`/`m3.bin` load,
not another register read.

`0425` adds that load path: `wififw` reads `/private/var/vm/amss.bin`, maps the
wired buffer through the W2 SMMU context, enables PCI bus mastering and passes
the first 512 KiB (ath11k's `sbl_size`) to BHI. Measured 2026-11-26:

- The five PM8350/PM8350C SMPS and all four shared resources complete when
  voted on **ACTIVE TCS4** (`mx.lvl` index 8, `cx.lvl` index 9, `xo.lvl` 3,
  `SN7`); the earlier wedge was TCS3, which the GPU leases.
- `RSC_DRV_STATUS` is zero while a TCS is busy and nonzero when idle; reading
  it inverted stalled every vote at the first rail.
- After both PCIe SIDs are routed (RID 0 → `0x1c00`, RID `0x100` → `0x1c01`),
  the load no longer resets the SoC. The BHI image address, size and doorbell
  read back, the WLAN SMMU FSR stays clean and `BHI_STATUS` stays `0x0`: the
  PBL never consumes the doorbell.
- `0438` runs ath11k's pre-load SOC reset (clear `WLAON_WARM_SW_ENTRY`,
  `PCIE_SOC_GLOBAL_RESET`, `MHICTRL.RESET`) from `wifibhi`.
- A 1 MiB BAR map stopped the worker at `W4 BAR map start` (256 io_submap
  pages). `0441` maps four BAR pages (MHI/BHI plus the AHB window register)
  and maps each AHB data page once.
- Measured 2026-11-26 with `0441`: W4 completes, W4/W5 read `MHIVER=0xdeadbeef`
  and `BHI ver 1.2 status 0x0`, and `wifistat` answers. `wifibhi 0x80000` then
  stops the command thread: the ring never answers again while the USB device
  stays enumerated, so the wedge is inside the load thread.
- Measured 2026-11-26 with `0442`: pre-mapping the AHB pages in W4 ends that
  wedge. `wifibhi 0x80000` returns `failed`, `wifistat` still answers, and the
  full W6 trace is: SOC reset (`qfprom 0x62`, `ctrl 0x4`, `MHICTRL 0x2`), AMSS
  ELF read of 5,470,128 bytes, SMMU `iova 0xa1000000`, bus master `0x6`,
  BHI address/size/doorbell written, then `BHI status=0x0` for 10000 polls with
  `gfsr=0` and `s2cr=0x4a/0x4a`. The PBL never polls.
- `0444` adds the first half of ath11k's power-on reset (`LTSSM 0x111`,
  `GCC_PCIE_HOT_RST`) and `ath11k_mhi_clear_vector`, which `0438` skipped.
- `0445`/`0446` test the endpoint interrupt: preserving the ROM's
  `BHI_INTVEC=0xffffffff` changes nothing, and arming the endpoint's MSI
  (capability `0x50`, 64-bit) on a page inside the wired buffer with bus
  mastering before the reset still leaves `BHI_STATUS=0x0` and the doorbell
  retained for 10000 polls. The PBL has not fetched. `0447` reads
  `TCSR 0x224=0x400c1211` (`hw_major=2`) and selects the donor's hw2.0 image
  `amss20.bin` (5,296,128 B); the boot that loads it (`image=0x50d000`) reports
  the same `BHI_STATUS=0x0`, `BHI_ERRCODE=0x0` and `MSI page=0x0`, so the image
  is not what the PBL waits for. `wififw` is one-shot per boot: a second load
  selects the new file but W2 refuses the re-route (`sid2 0x1c00 conflicts
  slot 7`), so a firmware change needs a reboot.
- `0449` programs the MHI context the PBL reads (`CCABAP`/`ECABAP`/`CRCBAP`,
  control and data base+limit, `MHICFG` NER/NHWER) from a zeroed page at
  `0xa15ff000` before the doorbell. Measured 2026-11-26: `MHICFG` reads
  `0x800080`/`0x800080`, `CHDBOFF=0x300`, `ERDBOFF=0x700`, `BHIEOFF=0x224`,
  `CCABAP` reads back, `MHISTATUS=0x0`, and `BHI_STATUS` is still `0x0` after
  10000 polls.
- `0450` programs the PARF requester table (`0x2000`, 256 entries) with this
  endpoint's BDF at the CRC8 index (`crc=0x15`, entry `0x01000100`) and clears
  `0x2c00` bit 0, as the donor's `coldLink` does, so the endpoint's DMA cannot
  reach the SMMU as an unmatched stream. No change: the PBL still does not fetch.
- `0451` reads the endpoint's PM capability: `PMCSR=0x8`, state 0, so the
  function is in D0 with bus mastering on (`command=0x6`); that is not the gate
  either.
- `0454` dumps the BHI descriptors around the doorbell. Measured 2026-11-26:
  `ver=1.2 arl=0 numseg=1 exec=0` before the host SOC reset and after it,
  byte for byte the same, so the reset does not change the BHI block; the
  doorbell written afterwards still reads `0x2a5a5a5a` at 1, 10 and 100 ms
  and `BHI_STATUS` never leaves 0. A retained doorbell does not prove it was
  ignored (0459).
- `0456` is the A/B for the host reset: `mondrianwifinorsoc=1` skips the
  `PCIE_SOC_GLOBAL_RESET` pulse and the `MHICTRL` reset, so the doorbell lands
  in the ROM the cold power-up left running. Measured 2026-11-26: `W6 soc
  reset skipped`, then the same `W9` values and `txdb=0x2a5a5a5a` at 1/10/100 ms
  with `status=0`. `0493` moves the skip to the top of `wifi_soc_reset`, so
  it also skips the LTSSM/hot reset, the QFPROM bit and the warm-entry
  clear; measured 2026-11-27 the stage is still `0xef0a0111` with `status=0`.
  No host reset is the gate, so `0456`'s partial A/B and `0493`'s full one
  agree. The pre-BHI MHI context (`W8`) is the next host step to take out:
  mainline, the working SM8475 driver and the donor all program it after the
  SBL, and the 8 KiB map leaves its page unreachable.
- The stock `image/qca6490` holds only `amss.bin` and `amss20.bin`, so the
  `0x400c1211` word's minor `0x11` (WCN6855 hw2.1 in ath11k) selects no third
  image.
- The host side is complete: identity, link, SMMU, MHI context, BHI registers
  and MSI all read and write the way ath11k does, no SMMU fault is recorded, and
  `BHI_STATUS` never leaves 0. Reading `BHI_IMGTXDB` back does not tell whether
  the doorbell was consumed: the PBL does not clear it (0459).
- `0457` repeated the A/B on the rebuilt series with the same result (`soc
  reset skipped`, `txdb=0x2a5a5a5a` at 1/10/100 ms, `status=0`).
- `0458` reads the device side. Measured 2026-11-26: the five rail PPIDs
  (`49e/1b9/1b6/29b/1bc`) are in the SPMI arbiter map but **owner 4**, the
  secure world that also owns the RTC, so APPS cannot read a regulator back at
  all (the helper refuses a non-AP-owned PPID before issuing a transaction,
  which is why the answer is zero and not a fault); only the RPMh vote exists
  and it is acknowledged. GPIO82
  (`qcom,sw-ctrl-gpio`) already reads high and no stage drives it. `MHICTRL`
  written `0x2` reads `0x2` at once and `0x0` after 10 ms, so the MHI reset is
  accepted, while BHI still reports `ver 1.2 serial 0x907d3a8b hwid 0x1016d0e1
  exec 0`.
- `0459` settles that last point the other way: with `BHI_IMGADDR` pointed at an
  unmapped IOVA (`mondrianwifibad=1`, `0x0bad0000`), the SMMU reports
  `fsr=0x402 far=0x0bad0000 gfsr=0`, so **the PBL does consume the doorbell and
  start its fetch**; with the real image it reads through the wired window and
  the SMMU records nothing. The doorbell is not the gate; the transfer or the
  SBL start is (open).
- `0460` shrinks the SMMU window to the 512 KiB BHI advertises
  (`mondrianwifimap=524288`). Measured 2026-11-26: no fault appears — the record
  is `fsr=0x400 far=0x4021404` before and after the doorbell — so the PBL makes
  one sequential transfer inside the advertised size and does not load ELF
  segments by file offset (segment 8 starts inside it and ends at `0x151000`,
  which would have faulted). The image is fetched as a blob; whether the code at
  its entry point runs is a separate question.
- `0462` lowers the endpoint's max read request size to 128 B
  (`mondrianwifimrrs=1`, device control `0x2810` to `0x810`, the value the
  donor's working boot writes) and reads the warm entry after the doorbell:
  no change, `status=0`, `cookie=0`.
- `0464` rings 4 KiB, 64 KiB and 512 KiB with distinct sessions and reads
  `BHI_STATUS` 500 ms after each: all `0`. The ack is not size-dependent; the
  PBL issues the reads and never reports one.
- `0447`'s image choice is confirmed by the donor: its QMI on the same chip
  returns `soc_id 0x400c1211`, `board_id 0xff` and loads `amss20.bin`, the same
  value `TCSR 0x224` reads here. Its working SMMU context is also the state
  `0418` already programs (`SCTLR=0x27`, `TCR2=0x38071`, ASID `0x1c01` in
  TTBR0), so the context is not what differs; the donor's ladder and the Linux
  MHI reference are in `docs/REFERENCE_PORTS.md`.
- `0465`'s bypass probe used the zizhan splash address (`0xb8000000`, not this
  board's): measured 2026-11-26, `ml_io_map()` of it wedged the worker at its
  first statement and the reset's own mapping with it, so the reset lost the
  reason and landed on `boot_b`. `0467` takes the image from 64 KiB of
  contiguous kernel memory and programs both halves of `BHI_IMGADDR`.
- The reset's two mappings -- the IMEM word and the SPMI SDAM window -- are now
  taken in the boot probe block, before any worker (`0466`, `0468`, `0469`),
  because a second `ml_io_map()` racing a worker that maps wedges both.
  Measured 2026-11-26: `restart window ready apid 412`, and the ring's `reboot`
  with the Wi-Fi driver loaded lands in fastboot in 4 s.
- Expected, not proven: with the 20 s auto-load delay the worker stops before
  `wifi_w10_probe()`'s first line, so the first TLMM/config access after the
  endpoint idles does not return. `mondrianwifidelay=0` is the workaround until
  the link is kept awake across the delay.
- `0469`-`0481` move every window the worker touches onto the boot thread,
  because `ml_io_map()` is serialized and blocks behind any other mapper.
  Measured 2026-11-26: the stop moved with each premap -- `W4 BAR map done`
  (0469), `pcie0 link up` with `qca6490 id` absent (0470), `pcie0 gdsc up`
  inside `wifi_map_host()` (0473) and `early GCC 0x62008` inside
  `wifi_map_pins()` (0474) -- so the window was never the fault. Three traps
  came out of the ladder:
  - `EUSB2_PA` was mapped in three places; one shared page (`0478`).
  - Writing the eUSB2 PHY while it is unclocked hangs the AHB, and with it
    `gadget_start` and the kernel command thread (`0477`: `wifistat` no answer,
    no `probe done`). Both `eusb2_init()` sites read first and skip the writes
    on `0x09090909`/`0xffffffff` (`0480`).
  - The TLMM pin pages must be mapped **before touch takes the TLMM block**;
    a later `ml_io_map()` of an already-mapped page hangs. The premap runs at
    the top of `mondrian_wifi_premap()`, and the worker starts last, after the
    BT registration (`0479`, `0481`).
- The driver-side ring is the XNU `msgbuf`: it is circular, mixes late
  SpringBoard lines with the banner, and its length varies with the boot, so a
  missing worker line does not prove the worker did not run. `wifistage` over
  the USB command channel is the state query, and `wifibhi <size>` drives
  `mondrian_wifi_load_amss()` from the command thread. Do not send `wifistat`
  before the worker has voted the rails: reading `BAR0+0x28` on a collapsed
  device hangs the command thread.
- Measured 2026-11-26: a Wi-Fi boot with `0485` panics with
  `kmem_%s(...): failed with %d` (`__kmem_failed_panic`, `vm_kern.c:177`) on a
  `0x4000` allocation. After startup `io_map()` is the only `kmem_alloc` with
  `KMA_NOFAIL`, and it allocates from the 8 MiB `io_submap` with
  `KMA_NOFAIL|KMA_PAGEABLE|KMA_PERMANENT`; the panic's map is that submap, not
  `kernel_map`, and the SMMU tables are not it either (`kmem_alloc_contig`
  without `NOFAIL`, 0x7fff). `0485` had added a seventh `ml_io_map()` to the
  premap. `0486` maps one 16 KiB TLMM window per four pins and derives GPIO 82
  (sw_ctrl) from GPIO 80's window, so the premap takes four mappings and none
  of its own. Measured 2026-11-27: that boot answers the ring and reaches
  `wifistage 18`; the worker logs `W10 pads ... sw=1/1` and `W6 BHI trigger
  iova=0xa1000000 sbl=0x80000 image=0x50d000 rc=0x0`, and `IMGTXDB` still
  holds `0x2a5a5a5a` at 1, 10 and 100 ms with `BHI_STATUS=0` after 10000
  polls. With `mondrianwifibypass=1` the same boot dies right after `W15
  bypass rc=-1`, so that diagnostic stays off until its path is fixed. The
  doorbell being retained and `status=0` is not a host-sequence gap: the host
  matches Linux `mhi_fw_load_bhi` (clear `BHI_STATUS`, write `IMGADDR`
  high/low and `IMGSIZE`, ring `IMGTXDB` with a non-zero 30-bit session).
  `0487` replaces the no-op `flush_dcache64()` calls (the kernel is
  `__ARM_COHERENT_IO__`, so they were a bare `dsb`) with a real dcache clean;
  the boot still reports `status=0`. With only 8 KiB mapped
  (`mondrianwifimap=8192`) the SMMU sees no read past `0xa1002000`, so the
  PBL reads only the ELF header and hash segment and stops. `0489` reads the
  boot-ROM telemetry after the poll: `TCSR_PBL_LOGGING=0xef0a0111` (stage
  `0x0a`, authentication), `WLAN_SECURE_BOOTN=0x0`, `PBL_WLAN_BOOT_CFG=0x1`,
  `WLAON_SOC_POWER_CTRL=0x8020397` and `WL_PWR_STATUS=0xd`. The secure and
  WLAON state matches stock, so the doorbell, SMMU and power rails are not
  the gap. The first-512 KiB image sum `0x163c3337` is the phone's own stock
  `amss20.bin` from `modem.img` (sha256 `903c378a…`), and its ELF header
  reads `e_entry=0x1436500` with 17 program headers, the same as the donor,
  so the image is correct and the earlier `0x57da4435` comparison was wrong. The QCA6490 PBL
  log is 10 words at `0x01403da0`, not the QCA6390 base: measured
  2026-11-27 it ends `42100000 2 80f7d0 b2 ef000008`, the same last five
  words the Pixel 7a reads at its authentication stop, so the ROM fails in
  common code, not in the host DMA path. `WLAN_SECURE_BOOTN` reads 0 three
  times and `0x01e22b2c`/`0x01e22b3c` read `0x800000`/`0x1016d0e1` (the
  JTAG id). That is the value the 7a reads only once its **AoC** has
  bootstrapped the chip before `WLAN_EN`; without the AoC its PBL stops at
  the same `pbl_auth.c` site with `SECURE_BOOTN=0x11111111`, and the fix was
  loading `aoc.bin` before power, not a host change. So the strap is a
  platform input, not the register alone, and stock also never loads the
  first `WLAN_EN` cycle: it powers and enumerates once, drops `WLAN_EN` with
  the buck held, and loads on the second rise. On mondrian the strap is
  settled the other way (`0x0`), so the missing input is not the same one.
  `0492`'s odd doorbell session, `0493`'s skipped reset, `0494`'s removed
  pre-BHI MHI context and `0495`'s idle first `WLAN_EN` cycle all leave the
  stage at `0xef0a0111` and `BHI_STATUS=0`; `PBL_WLAN_BOOT_CFG` reads `0x1`
  against stock's `0x0` before a good load and `0x200` after one, and the
  bootstrap/OD/SVS reads hang after the stall, so they stay out. `0496` maps
  the whole 6 MiB buffer, so the MSI landing page at `iova + 0x5fe000` is
  reachable, and arms the working driver's `0xa500` data word. The page is
  still 0 after the poll and the SMMU records no read past the hash segment
  (FSR holds only the AArch64 format bits), so the PBL neither raises the MSI
  nor loads a segment. The remaining difference is an input the platform must
  supply before `WLAN_EN`, not a host sequence.
- BHI, per Linux `drivers/bus/mhi/host/boot.c`: the block is at
  `BAR0 + BHIOFF` (`BHIOFF` read from `BAR0+0x28`, `0x100` on this family), so
  doorbell `+0x18`, `EXECENV +0x28`, `STATUS +0x2c`, `ERRCODE +0x30`. BHI only
  runs when `EXECENV == 0` (PBL); `IMGTXDB` is a non-zero 30-bit session id and
  Linux polls for up to 20 s. The PBL reads the image with the function's
  requester ID, so the **PARF BDF->SID table** (`PARF 0x2c00` bypass bit,
  `0x2054`) must route it to the same SID (`0x1c01`) the SMMU context covers;
  the iATU is host->BAR only. ath11k keeps the coherent mask at 32 bits, so
  the image must sit below 4 GiB. `m3.bin` is not part of BHI; it arrives over
  QMI after `FW_MEM_READY`. When `BHI_STATUS` never reaches 2, read
  `MHISTATUS` (`BAR0+0x48`) bit 0 after the attempt: `1` means the SBL is
  running and the gap is BHIe, `0` means the PBL never handed over and the
  image/address/session is the gap. `wifistat` reports it once the worker has
  mapped the host windows.

Arming the worker needs **both** `mondrianwifi=1` (the gate in
`mondrian_wifi_start()`) and `mondrianwififw=1` (the auto-load at W4). With
only the second, `wifistat` reports `stage=0` and every register stays zero,
which looks exactly like a failed firmware load. The two arguments plus the
default command line are 585 bytes; adding `mondrianwifidelay=5000` reaches
608 and `mkpayload.py` refuses it (iOS reads `kern.bootargs` into a 608-byte
buffer, so an overlong line fails with ENOMEM).

The load thread runs that reset, the 6 MiB AMSS read, the SMMU map and the BHI
writes in sequence; `0430`/`0431` carry the BHIE stage and the live
`wifibhi`/`wifistat` commands.

The shim unpacks the payload in place: a kernel carrying the 4.87 MB UI/GL
`glblob` produced a 16.8 MB payload and never reached XNU, while 15.7 MB boots.
Build WiFi images without the UI/GL dylibs until the payload fits the shim
window; the `glblob` boot argument has nothing to write in that build.

This document records the hardware, what the iOS userland expects, what the
existing ports teach, and what is left.

## The hardware

From the live device tree (`/private/tmp/live.dtb`, `bluetooth` and `wlan`
aliases):

| Half | Bus | Nodes | Linux driver |
| --- | --- | --- | --- |
| WiFi | PCIe 0, `pcie@1c00000` endpoint | `qcom,cnss-qca6490@b0000000`, `cnss_pci`, `cnss_pins` | `cnss2` loads the firmware and brings up MHI; `ath11k` drives the WLAN |
| Bluetooth | QUP UART (`hci_qca`) | `bt_qca6490`: reset, sw-ctrl and xo GPIOs, eight rails, `mboxes` | `hci_qca` (UART), `btqca` (power) |

### The Bluetooth UART, as the live tree has it

Measured on `dtb/mondrian-live.dtb` with `tools/dtb-dump.py` (the host has no
`dtc`; the phandles are resolved because a pin number and a regulator are the
part that is easy to misread):

```
tools/dtb-dump.py dtb/mondrian-live.dtb 'qup_uart@894000'
tools/dtb-dump.py dtb/mondrian-live.dtb 'bt_qca6490'
```

- **High-speed UART**: `/soc/qcom,qup_uart@894000`, `qcom,msm-geni-serial-hs`,
  `reg` **0x894000 + 0x4000**, `status` ok, `qcom,wakeup-byte` **0xfd**. It sits
  in the `qupv3_2` GENI wrapper at **0x8C0000** (`qcom,wrapper-core`), with
  `gcc` (`clock-controller@100000`) clocks `0x82` (se), `0x8a` (m-ahb), `0x8b`
  (s-ahb). Four pinctrl states: default, active, sleep, shutdown.
- **Interrupts**: GIC SPI **587**, level high, plus a wakeup line from
  `pinctrl@f000000` GPIO **79** (`interrupts-extended` = `<gic 0 587 4>`
  `<pinctrl 79 4>`).
- **The console UART is the other one**: `/soc/qcom,qup_uart@99c000`,
  `qcom,msm-geni-console`, SPI **608**. Do not bring that one up for Bluetooth.
- **BT node** `/soc/bt_qca6490` (`qcom,qca6490`): reset GPIO **81**, switch
  control GPIO **82**, WLAN reset GPIO **80**, XO clock GPIO **204**, all on
  `pinctrl@f000000`; `mboxes` = `qmp-aop` index 0.
- **Rails**, with the DT's own min/max/load/enable and the regulator each names:
  `vdd-aon`, `vdd-dig`, `vdd-rfa-0p8` and `vdd-rfacmn` → `pm8350 S11`
  (0.966–1.17 V); `vdd-io` → `pm8350 S10` (1.8 V); `vdd-asd` → `pmr735a L7`
  (2.8 V); `vdd-rfa1` → `pm8350c S1` (1.9–2.04 V); `vdd-rfa2` → `pm8350 S12`
  (1.35–2.024 V); `vreg_ipa` → `pmr735a S3` (2.2 V).

The QUP side now exists in the kernel (`0343`, below); nothing powers the chip
yet — no rail and none of the three GPIOs — so the firmware load is still the
step after that.

### The engine, the UART and the wire (measured)

`0343` maps wrapper 2, SE5 and GCC, votes the five bits of 0x62010 and reads the
identity registers; `tools/usb-ring.py` runs it from the host. Three stages,
each one proof for the next:

```
btuart         identity registers with the clocks voted
btuart loop    programs 8N1 and sends a byte into its own loopback
btuart baud    the same, on the 14745600 root: 115200 exactly
btuart power   the rails and pins powering the chip would touch (read only)
btuart on      BT_EN / XO / SW_CTRL in the vendor's order, then the pinmux
btuart hci115  HCI_Reset and Read Local Version on the 14745600 root
btuart tx115   the same send with no listen, to split TX from RX
btuart cmd <hex>   one raw HCI packet out and its reply back
btuart cmd0 <hex>  the same send with no read: the firmware burst needs it
btuart regs    GENI/M/S status and both FIFO counters (read only)
btuart cts     the CTS pad level and the TX config's CTS bit (read only)
btuart flow    honours CTS for a probe and leaves it that way for the next stage
btuart baud    the UART loopback, for a wire that reaches no chip
```

A stage that prints more than the reply buffer holds **corrupts the kernel**.
`mondrian_bt_step()` appends with `snprintf(out + n, len - n, ...)`, and `n` past
`len` underflows that size into a huge one: `btuart power`'s seventeen lines ran
past the handler's buffer, the answer came back truncated with binary junk, and
the command channel was dead from the next command on — the same symptom as a
real wedge, from an unrelated cause. Both ends are fixed now (the accumulator
stops appending and keeps printing to the ring, and the handler owns 1152 bytes,
one datagram under the interface MTU).

Three things take the command channel down with ICMP still answering, and none
of them is the clock:

- **`ml_io_map()` on every invocation.** `mondrian_bt_map()` mapped ~480 KB
  (GCC `0x70000`, wrapper `0x2000`, SE `0x4000`) each time a `btuart` command
  ran. The first command of a boot worked and the next one died on its first
  register read, which read as "`0xFC00` wedges the engine" for three boots: the
  EDL commands were never the problem. The three mappings are cached in statics
  now, and four engine commands in one boot are measured working. Any new driver
  here maps its windows once and keeps them.
- **`btuart power` between `btuart on` and the wire stage.** With the read-only
  probe in the middle the send killed the channel twice; without it the same
  stage came back with the chip's first event byte. Run the probe after the wire
  stage or not at all; `tools/wsl/bt-stage.sh` does.
- **`mondrian_bt_rcg_14745600()` did not gate the branch.** It now drops SE5's
  vote for the duration of the M/N/D and parent change and restores it after,
  which is what the clock framework does around `set_parent()`. Whether that is
  strictly required is unmeasured, but the stage completes with it.

Measured on the kernel of 2026-11-16, with the control channel still answering
afterwards (`pos` and `thermal` both came back, so the reads do not wedge the
bus):

```
btuart: vote 0x0 -> 0x20f want 0x20f granted
btuart: rcgr cmd 0x0 cfg 0x100000 (was already rooted)
btuart: halt se5 0x4220 m-ahb 0x0 s-ahb 0x80000002
btuart: wrapper2 hw ver 0x30080000
btuart: se init 0xa
btuart: se cgc 0x7f
btuart: se clk 0x1
btuart: se fw 0x204
```

Read it as: the vote register came back **0 with nothing set** (no earlier boot
or bootloader step powers this engine), the write sticks (`0x20f` = core 2x,
core, m-ahb, s-ahb, SE5), the SE clock root was **already on** so the XO
fallback did not run, bit 0 of the SE5 halt register is clear (the engine is not
halted), and the engine reports a GENI init-config revision of **0xa**, `CGC_CTRL`
0x7f, `CLK_CTRL_RO` 1 and a firmware revision of **0x204** (protocol UART, already
loaded).

The UART stage, measured on the kernel of 2026-11-17 with `pos` answering
afterwards (`269963`):

```
btuart: fifo tx 16 words x 32 bits, rx 32 words
btuart: uart 8n1 div 10 (xo 19.2MHz -> 120000 baud) loopback 1 status 0x41000
btuart: m_cmd0 0x8000000 status 0x41000 -> 0x41041
btuart: tx fifo filled 0x10000000
btuart: tx 1 bytes done 1 irq 0x40000001 tx_fifo left 0x0
btuart: rx fifo status 0x90000001, 1 bytes
btuart: rx data: 5a
```

With no chip powered, the same sequence prints `4 bytes` out and
`rx data: (nothing)`: the engine completes and the wire is silent.

Four traps in that sequence, each one a boot when it was wrong, all settled by
mainline `qcom_geni_serial.c` / `qcom-geni-se.c`:

- `SE_UART_TX_TRANS_CFG` (0x25c) bit 1 (`UART_CTS_MASK`) must be **set** with no
  hardware flow control. Cleared, the TX command latches (`M_GENI_CMD_ACTIVE`
  comes on, `status …41`) and never completes: `done 0`, `M_IRQ_STATUS` 0.
- The TX command starts **before** the FIFO is filled: `SE_UART_TX_TRANS_LEN`,
  `M_CMD0` = `UART_START_TX << 27`, then the FIFO. Filling first leaves
  `TX_FIFO_STATUS` at 0 — the writes do not land.
- `SE_GENI_BYTE_GRAN` (0x254) is 0 for 8-bit words (`bpw / 16`). What the
  bootloader leaves there swallows byte writes.
- Depths come from `SE_HW_PARAM_0/1` bits 21:16 (16 TX words of 32 bits, 32 RX),
  not a guessed 62; `SE_GENI_RX_STALE_CNT` (0x294) is 160 (`10 * 16`); packing is
  8 bits, four words per entry, lsb first (`TX_PACKING_CFG0` 0x4380e, `CFG1`
  0xc3e0e), and the TX FIFO holds four bytes per 32-bit entry.

The loopback proves the engine and the framing, **not** the baud: div 10 off the
XO is 120000, 4 % high. The ROM needs 115200 exactly, and the QUP source table
already has it: `F(14745600, P_GCC_GPLL0_OUT_EVEN, 1, 768, 15625)` in
`gcc-sm8450.c`, and `14745600 / (8 * 16) = 115200`. `gcc_qupv3_wrap2_s5_clk_src`
has `mnd_width = 16`, so the SE root takes the fractional M/N, and the SER
divider is 8.

`btuart baud` programs that and reads it back exactly (measured):

```
btuart: rcg cmd 0x2 cfg 0x102601 m 0x300 n 0xc5f6 d 0xc2f6 -> 14745600 Hz
```

`cmd 0x2` is `ROOT_EN` with the update latched, `cfg 0x102601` keeps the hardware
clock-control bit (20) and sets parent 6, pre divider 1 and dual-edge mode, and
the M/N/D fields are `~(N - M)` and `~N` as `clk-rcg2.c` writes them. The write
must be a read-modify-write of `CMD_UPDATE`: a plain write of `0x1` clears
`ROOT_EN`.

Its loopback, measured after the fix that cancels the previous stage's secondary
command (`btuart baud` twice in a row, and 5a both times):

```
btuart: uart 8n1 div 8 (root 14745600 -> 115200 baud) loopback 1 status 0x41000
btuart: tx 1 bytes done 1 irq 0x40000001 tx_fifo left 0x0
btuart: rx data: 5a
```

So the engine frames at the rate the RCG was set to. 115200 itself is derived
from that readback (14745600 / (8 × 16)).

With the chip powered, the same stage answers (measured: `btuart on` then
`btuart hci115`, no probe in between):

```
btuart: rx data: 04 0e 04 01 03 0c 00
btuart: rx data: 04 0e 0c 01 01 10 00 0b 00 00 0b 1d 00 e6 38
```

Decoded: the Command Complete of `0x0C03` (`HCI_Reset`) with status 0, then the
Command Complete of `0x1001` (`Read Local Version`) with status 0, **HCI 0x0B
(5.2)**, HCI revision 0, **LMP 0x0B (5.2)**, manufacturer **0x001D (Qualcomm)**
and LMP subversion **0x38E6**. The ROM runs at 115200 with no patch loaded, and
`btuart edl115` (`0xFC00`/`0x19`, btqca's `EDL_PATCH_VER_REQ_CMD`) is what names
it next.

Two bugs truncated those events first, both in the drain: it treated
`SE_GENI_RX_FIFO_STATUS` as a byte count when bits 24:0 count **words** (with
`RX_LAST` bit 31 and `RX_LAST_BYTE_VALID` 30:28 for a short last word), and it
stopped at the first byte. The wire never lost a byte.

A boot used for that test carries **`mondrianreset=120`**. `0127`/`0133`/`0220`
run a thread that flushes the ring, points the BCB at `boot-fastboot` and resets
the SoC, so a wedged kernel returns to fastboot about two minutes later with no
key presses (`mondrianresetrecovery=1` lands in the recovery instead, where adb
reads the ring). The board cmdline ships `mondrianreset=0`, which is why both
wedges above needed the buttons; the test image is the one place to add it.
Reaching fastboot from a healthy iOS is the ring's `reboot` (`0309`), which
writes the PMK8350 restart reason over SPMI — a dead command channel takes that
away too, so the timer is the only unattended way back.

### What powering the chip needs

The eight rails are RPMh resources, not SPMI registers: the live tree's
`qcom,bt-vdd-*-supply` resolves to `qcom,rpmh-vrm-regulator` nodes under
`/soc/rsc@17a00000` with `qcom,resource-name` **smpb11** (S11: aon, dig,
rfa-0p8, rfacmn), **smpb10** (S10: io, 1.8 V), **smpb12** (S12: rfa2),
**smpc1** (pm8350c S1: rfa1), **ldoe7** (pmr735a L7: asd, 2.8 V) and **smpe3**
(pmr735a S3: ipa), all with `qcom,set 3` (active and sleep). That is an AOP vote
with a voltage and a mode, the same door the GPU votes in `0170` use, not
`mondrian_spmi_reg_write()`.

The three GPIOs are `qcom,bt-reset-gpio` **81**, `qcom,bt-sw-ctrl-gpio` **82** and
`qcom,xo-clk-gpio` **204** on `/soc/pinctrl@f000000`, which is
`qcom,cape-pinctrl` (`reg` 0xf000000 + 0x1000000) and uses mainline's tiled
layout: per-pin offsets come from the SoC's pinctrl table, so a guessed
`0x1000 * gpio` is wrong here. `bt_en_sleep` in that node is
`bias-pull-down, drive-strength 2, output-low`, i.e. the tree's own idea of the
chip being off.

Measured with `btuart power` (read only), which is what the vote will be written
against:

```
btpower: smpb11 addr 0x40000 want 966 mV aux 4 bytes
btpower: smpb10 addr 0x40700 want 1800 mV aux 4 bytes
btpower: smpc1 addr 0x40200 want 1900 mV aux 4 bytes
btpower: smpb12 addr 0x40100 want 1350 mV aux 4 bytes
btpower: ldoe7 addr 0x41600 want 2800 mV aux 4 bytes
btpower: smpe3 addr 0x43400 want 2200 mV aux 4 bytes
btpower: gpio 79 cfg 0x1 io 0x0
btpower: gpio 80 cfg 0x1 io 0x0
btpower: gpio 81 cfg 0x1 io 0x0
btpower: gpio 82 cfg 0x1 io 0x0
btpower: gpio 204 cfg 0x801 io 0x0
```

All six resources are in the cmd-db under the names the tree uses, so the vote
needs no name translation; the aux data is 4 bytes (a single kind value, not the
linear range the GPU rails carry). The four pins the chip drives read
`cfg 0x1` — alternate function 1, chosen by the loader, not GPIO — and `io 0x0`.
Pin 204's page is at `0x0f100000 + 0xcc000` and reads `cfg 0x801`.

The sequence is the vendor driver's (`drivers/bluetooth/btpower.c`,
`bluetooth_power(on = 1)`), and its names matter more than its register writes:

- **GPIO 81 is `BT_EN`**, an active-high *enable*, not a reset pulse: drive it
  low first, sleep 50 ms, and the part is off while the rails settle.
- **GPIO 204 is the XO clock buffer**: raise it 100-200 µs *before* `BT_EN`, and
  drop it again a few ms after, because the part latches its clock at reset
  release.
- **GPIO 82 is `SW_CTRL`, an input**: after 50 ms the part drives it high to say
  it is running, so it is the first thing to read once `BT_EN` is high. A low
  level means the part did not come up (the vendor then asserts a debug GPIO).
- The rails come first, then the pins; the tree's own `bt_en_sleep` state
  (`output-low`) is `BT_EN` low, i.e. the chip off.

The pin encoding is the touch driver's, which already drives this controller:
`(function << 2) | pull | (drive << 6) | (output << 9)`, level written to
`IN_OUT` before `CFG` so enabling the output does not drive a stale value.

`btuart on` does that with **no rail vote at all**, and the part came up
(measured):

```
btpower: bt_en low, 50 ms
btpower: bt_en high, xo on
btpower: sw_ctrl 1 (the part says it is up)
btpower: gpio 79 cfg 0x1 io 0x1
btpower: gpio 80 cfg 0x1 io 0x0
btpower: gpio 81 cfg 0x2c0 io 0x3
btpower: gpio 82 cfg 0x0 io 0x1
btpower: gpio 204 cfg 0xac0 io 0x0
```

So the loader's supply is enough for the chip to run its ROM, and the only
things missing were the three lines: `BT_EN` (81) ends as output high
(`cfg 0x2c0`, `io 0x3`), `SW_CTRL` (82) is an input reading **1**, and the XO
buffer (204) is back low after the switch. Voting the rails is therefore *not*
on the path to the first HCI packet; `btuart vote` keeps it for later.

The UART does **not** use those pins. `qup_uart@894000`'s `pinctrl-0` is
`qupv3_se20_4uart_pins` — 76 cts, 77 rts, **78 tx**, **79 rx** (SE20 is the
vendor's numbering for the engine at 0x894000) — and its *default* state muxes
all four as `gpio` (78 with a pull-up, 77/79 pull-down) while its *active* state
muxes them as `qup20`. The vendor flips to active when it powers the part, and
this kernel left them parked: the HCI_Reset left the SE and stopped at a pad
configured as a GPIO, which is exactly the silence that was measured. `qup20` is
fsel **1** (mainline's per-pin list starts with `gpio`), so the mux is
`CFG = 1 << 2` with no pull and 2 mA, the tree's own `bias-disable,
drive-strength 2`.

GPIO 79 carries two jobs: it is the UART's RX **and** the node's wakeup source
(`interrupts-extended` names `<pinctrl 79 4>` and `wakeup-parent = <&pdc>`).
The loader leaves that pad's interrupt enabled (`INTR_CFG` read **0xe2**), so
the moment the mux makes the line live, the chip's traffic is an interrupt this
kernel does not acknowledge — and the wire stage died exactly then, with the
same storm signature as the SE line. `btuart on` masks the pad (`INTR_CFG = 0`)
and clears the latch (`INTR_STATUS = 0xffffffff`) before muxing, and prints both
values back.

Voting them is also what took the command channel down once: `btuart vote`
writes the six voltages and enables through one RPMh TCS each, and those SMPS
are shared, with 4 bytes of aux data instead of the linear range the GPU rails
carry. That path is opt-in and unproven until there is evidence the loader
leaves them off.

Before writing either, dump what the vendor kernel leaves behind: an OrangeFox
`fastboot boot` (ten seconds, writes nothing) reports the rails
(`/sys/class/regulator/*/state`) and the pin state
(`/sys/kernel/debug/pinctrl/*/pinconf-pins`) of the same hardware.

- The WiFi part is a WCN6855-class device (the QCA6490 is its board-level
  name). Linux firmware: `ath11k/WCN6855/hw2.0/amss.bin`, `m3.bin`,
  `board-2.bin`, `regdb.bin`. `board-2.bin` is board-specific; the stock
  vendor partition has the calibrated copy.
- The Bluetooth part is the same die's BT core, reached over its own UART.
  Firmware is a RAM patch plus an NVM file from the `qca/` family
  (`nvm_00190200.bin` and the matching `rampatch_*`; the ROM version read from
  the chip selects the exact file).
- Both halves need the PMIC rails in the DT and the `cnss`/`bt` reset GPIOs.
  Nothing powers them today: there is no PCIe host driver and no QUP UART
  driver in this kernel.

### The firmware, and where it comes from

The blobs are not in this tree and no recovery boots here (`AGENTS.md`), so the
source is the stock ROM. A xiaomi.eu fastboot ROM ships `images/bluetooth.img`,
a **FAT16** volume whose `image/` holds the whole BT firmware set:

| file | size | what |
| --- | --- | --- |
| `hpbtfw20.tlv` | 201,560 | patch, `BTFW.HSP.2.0.1-00252-HSP_PATCH-1`, `QCA6490ROM=0200` |
| `hpbtfw21.tlv` | 146,068 | patch, `BTFW.HSP.2.1.0-00570-PATCHZ-1`, `QCA6490ROM=0201` |
| `hpbtfw20.ver` | 33 | the 2.0 build string as text |
| `hpnv20.*`, `hpnv21.*` | ~6.3 KB | NVM, **one per board ID** (`hpnv21.301`, `hpnv21.b10c`, …), plus `g` variants |

113 files, 3.4 MB. Which patch applies follows the ROM build (EDL version and
build info, `0xFC00` with `0x19`/`0x20`) and which NVM follows the board ID
(`0xFC00` with `0x23`), so the loader asks both before it picks a file — btqca's
`qca_read_soc_version` and `qca_read_fw_board_id` do exactly that.

The trees are archived outside the repo at `C:\Users\Pedro\mondrian-firmware`
(`bluetooth/`, `vendor/`, `raw/{bluetooth,vendor}.img`). To re-extract, `7z x
ROM.zip images/bluetooth.img` and mount the FAT. The rest of `/vendor` costs one
more step, because the ROM's `super.img` is split into nine **independent sparse
images of the whole partition** (each with its own header, DONT_CARE everywhere
it carries nothing): merge with `tools/sparse-merge.py`, then
`tools/super-extract.py super.img vendor_a vendor.img` (1.5 GB, **erofs**) and
`mount -t erofs`. `/vendor/firmware` is only 12 MB of audio and sensor blobs;
the Bluetooth firmware lives in the separate `bluetooth` partition.

Downloading it needs no TLV parser: btqca streams the **file itself** in 243-byte
pieces, each as HCI `0xFC00` with `[0x1E, length, data…]`, and the controller
parses the TLV (verified with `tools/bt-tlv.py`: `hpbtfw21.tlv` declares ROM
`0x0201`, product `0x0013`, download mode 3). Before the patch a WCN6855-class
chip wants `0xFC00` with `0x28, 0x01, 0, 0, 0`.

Measured on 2026-11-17, the ROM answers on `0xFC00` with
`[cresp][rtype][len][payload]`:

```
0x19             04 0e 12 01 00 fc 00 19 0c 13 00 00 00 e6 38 01 02 11 12 0c 40
0x20             04 0e 1e 01 00 fc 00 20 18 42 54 46 57 2e 48 53 50 …
0x23             04 0e 08 01 00 fc 00 23 02 00 00
0x28 01 00 00 00 04 0e 07 01 00 fc 10 28 13 03
```

The version payload is btqca's `struct qca_btsoc_version`, `{product_id,
patch_ver, rom_ver, soc_id}`, so this chip reports product **0x0013**, patch
**0x38e6**, ROM **0x0201**, soc **0x400c1211**. ROM `0x0201` **is** the
`hpbtfw21.tlv`/`hpnv21.*` pair and product `0x0013` matches what the file
declares; a loaded patch replaces `patch_ver` with the TLV's `0x5e81`, which is
how the download is verified. The build string is
`BTFW.HSP.2.1-00124-ROM-0…`, and the board ID is **0x0000**, which no
`hpnv21.<bid>` matches, so the NVM falls back to `hpnv21.bin`. The `0x28` reply
carries `cresp 0x10` and a length that does not match its payload: btqca sends
that command on the **WCN6750** path only, so it is out of this sequence.

**The pacing is part of the protocol.** `download_mode 3` in the patch TLV is
`QCA_SKIP_EVT_VSE_CC`, and `qca_tlv_send_segment` sends every segment with
`__hci_cmd_send` — no event waited for — while `qca_download_firmware` forces
`QCA_SKIP_EVT_NONE` for the last one, so the controller acks exactly once.
Waiting for a reply per segment cost a boot: 440 segments of empty 300 ms reads
(234 s), the rate then fell from 0.3 to 1.25 s per segment, and the command
thread died there while ICMP kept answering. `tools/bt-download.py` bursts with
`btuart cmd0` and verifies with a fresh `0x19`, which reports the patch's own
version (`0x5e81` in the TLV) instead of the ROM's.

The wedge itself was `mondrian_bt_send()` writing the TX FIFO blind: a word
written with the FIFO full stalls the AHB until the engine drains, so a
controller that stops draining holds the thread for ever. It polls
`TX_FIFO_STATUS` now (bits 27:0 count words, and `depth - wc` is the room, as
`qcom_geni_serial_write_fifo` does) and reports `tx fifo never drained at N of M`.
Measured on 2026-11-17: with CTS honoured (`btuart flow`), the patch downloads in
**17 s** and the chip then reports `patch 0x5e81` instead of the ROM's `0x38e6`,
which is the TLV's own patch version: the firmware is running. With the mask set
it took 234 s to reach 106920 bytes and then the engine stopped draining. The
CTS pad reads **0** (asserted, ready) at 115200 and stays there through the
transfer, so the stall was the vendor's flow control doing its job on a wire we
were transmitting over regardless.

**The NVM must be rewritten before it is sent, or the chip moves its own UART.**
The NVM's `EDL_TAG_ID_HCI` tag (0x11) carries the rate the controller switches to
when it applies the file, and the stock `hpnv21.bin` says `data[1] = 0x11` =
`QCA_BAUDRATE_3200000`. Sent untouched, the download succeeds and then **every**
later command goes unanswered at 115200, which reads exactly like a dead chip.
`qca_tlv_check_data` rewrites that byte (and sets the in-band sleep bit) to the
rate the driver will actually use, and `patch_nvm()` in `tools/bt-download.py`
does the same: `15 11` becomes `95 00` for 115200, two bytes and nothing else.

Measured after the rewrite: `0xFC17` with `[0x14, 0x00]` answers
`04 0e 05 01 17 fc 00 14` (status 0) and HCI_Reset answers
`04 0e 04 01 03 0c 00` (status 0), so the controller is alive and running the
patch. A Read Local Version right after comes back buried in `0xfd` filler: that
is the in-band-sleep wake traffic the HCI tag enables with `data[0] |= 0x80`, not
a lost packet. Two reading traps come with it — a `btuart` answer that starts
with `0xfd` is noise rather than data, and the `rx data:` line is one 192-byte
buffer (three characters per byte), so it truncates past about sixty bytes.

After the NVM, btqca disables SoC logging (`0xFC17` with `[0x14, 0x00]`), runs
HCI_Reset and reads the build info; `--steps post` does that.

**The vendor HAL already answered both questions.** Decompiling
`lib64/hw/android.hardware.bluetooth@1.0-impl-qti.so` (aarch64, stripped, so this
is `adrp`/`add` string cross-referencing plus the dynamic symbols):

- `PatchDLManager::TlvDnldSegment(int, int, unsigned char)` builds **byte for
  byte the packet this tree builds**: `0xfc00` and `0x1e` as literals, the HCI
  length as `seglen + 2`, then `memcpy` of `seglen` bytes from `index * 243`.
- It sends with `HciSendVsCmd` and reads **one event per segment only when its
  third argument is non-zero and the byte at `this+122` is zero**. An ack per
  segment is a switch the caller sets, not a property of the protocol.
- `PerformChipInit` runs `SocInit`, `PatchVerReq`, `GetAppVerCmd`,
  `EdlModeChange`, `SetBaudRateReq`, **`DownloadTlvFile`**, `GetBuildInfoReq`,
  `DisableInternalLdo`, `GetAddOnFeatureList`, `HciReset`.
- The transport keeps **hardware flow control on** for that transfer:
  `HciUartTransport::InitTransport` and `ConfigUart` log "HW flow control
  enabled", and `SocRxDWakeup` drops it only around a baud change — "Flow
  off->Change UART baudrate to 38.4kbs->send 0x00->Change UART baudrate to
  max->Flow on". So the download runs with CTS live, which is why `btuart flow`
  leaves the mask clear instead of restoring it.

Caveat: `TlvDnldSegment` has no call site in this build (two references, no
`bl`), so the loop is probably inlined elsewhere; the packet layout and the
conditional ack are the parts that carry over.

The exchange lives in `tools/bt-download.py`, driven over `btuart cmd <hex>`; the
kernel only puts bytes on the wire, which is also why the driver never
re-programs the SE root (a **second** RCG change in one boot takes the command
channel down: measured with `btuart baud` after another stage and again with
`edl115` after `hci115`).

## What iOS expects

Measured strings in the iOS 16.7.16 root:

- **WiFi.** `wifid` matches an `IO80211SkywalkInterface` service and speaks
  `Apple80211Get/Set(APPLE80211_IOC_*)`; the kernel side is Apple's closed
  `IO80211Family`, which this XNU build does not contain. A Wi-Fi menu
  therefore needs either that family (binary from an iPhone kernelcache, same
  build; ABI and symbol risk) or a compatible reimplementation of the
  controller/interface, its event channel and its data path.
- **Bluetooth.** `bluetoothd` is the whole stack, in user space. It supports
  `H4`, `H4BC`, `H4DS` and `H5` transports, opens `/dev/cu.bluetooth`, and
  looks for an `AppleBluetoothModule` service. The kernel only has to provide
  an HCI transport and the firmware loader; no Bluetooth protocol code is
  needed in the kernel. The transport and the vendor checks live in
  `bluetoothd`, and this root is ours to patch. Measured on 16.7.16: the primary
  path is an IOKit service — it opens `AppleBTHci`/`AppleBTMgmt` through
  `AppleBluetoothModuleUserClient`/`AppleBTHciUC`/`AppleBTMgmtUC` and reads a
  `ControllerChipset` property — which Apple ships inside the kernelcache, not
  in this root and not in stock XNU. The fallback is a character device: at
  `0x100026af8` it opens `/dev/cu.bluetooth` and, when that fails, at
  `0x100026b10` `/dev/uart.bluetooth`, both before logging "No valid serial port
  found (tried cu.bluetooth and uart.bluetooth)". `/usr/sbin/BlueTool` (9.7 MB)
  is the firmware loader the stack drives.

The root image is **HFSX** (`HX` signature), so `tools`' usual reader does not
open it: `hpmount` only accepts a native `H+` volume. 7-Zip reads it
(`7z l ios-root.raw`, paths under `iOSRoot/`), which is enough to inventory and
extract single binaries without booting the helper VM. That is how the two
facts below were measured: `bluetoothd` (8.9 MB) imports `_open`, `_close`,
`_read`, `_write`, `_ioctl`, `_select`, `_tcgetattr`, `_tcsetattr`,
`_cfsetspeed` and `_cfmakeraw`, and its startup calls `access(path, F_OK)` on
the two device paths before matching `IOServiceNameMatching("marconi-bt")` and
then `"bluetooth"`; the serial path is a termios conversation, not a pipe.

### The client session, and the node it needs

`bluetoothd` is half of the stack. Every client (SpringBoard, Settings, and
anything built on `BluetoothManager`) attaches its own session first, and on
this port that attach refused with `BTResult 9` before any IPC: no connection
reached the daemon, and neither the `com.apple.bluetooth.system` entitlement
(SpringBoard has it) nor the TCC stand-in nor a `MobileGestalt` answer changed
the result. The refusal is inside `MobileBluetooth`'s
`BTSessionAttachWithQueue`, whose prologue looks an IOKit service up --
`IOServiceNameMatching("marconi-bt")`, then `"bluetooth"` -- and returns 9 when
neither exists. The shim answers those two lookups inside `bluetoothd` only, so
every other process saw an empty registry.

Adding `/arm-io/bluetooth` to the ADT (`tools/mkadt.py`) makes the attach
return 0, and is the only change that has done so. The node carries what the
real D22AP node has -- `device_type`, `compatible = "bluetooth,n88"`,
`vendor-id`, `product-id`, `supported-profiles`, `coex`, `transport-encoding`,
`transport-speed` and `local-mac-address` (the address the shim publishes) --
because a node with only the address cleared the gate and left `_setup:`
reading absent properties. Userspace interposition of
`IOServiceGetMatchingService` is not a substitute: the client looks the service
up through paths the hook does not see.

The gate is necessary, not sufficient. With `bluetoothd` alive, the manager's
XPC reaches `kCBMsgIdLocalDeviceGetDefaultMsg` and gets a device id, and the
manager then powers the controller on its own: measured `powered after 13
tries available 1 session 0x283ffc240 device 0x702f0001` with every forcible
path disabled. Forcing the `available` ivar and calling `setPowered:` before
that -- while `_session` and `_localDevice` are still NULL -- makes
MobileBluetooth jump through a NULL `BTLocalDeviceSetPowerState` and kills
SpringBoard with SIGBUS (`pc == far`) before its first commit. The probe is
read-only by default; a `/private/var/vm/bt-force` marker gates both writes.

### The control bluetoothd opens

Measured in 16.7.16, `H4:POSIX` does not select a tty. The POSIX driver is a
kernel-control client: it creates a `PF_SYSTEM` socket, resolves
`com.apple.uart.sk.bluetooth` with `CTLIOCGINFO` (`0x100066d34`), connects, and
reads a 72-byte termios (`0x40487413`) and a 16-byte channel UUID
(`0x40105412`). The UUID goes to `os_channel_create()`; with no Skywalk nexus
it returns NULL, and the driver falls back to `write(2)` (`0x1000676a4`) and
`read(2)` (`0x100067a9c`) on the same socket.

`/dev/cu.bluetooth` is therefore not the HCI transport. `FindLocalMacAddress`
`access()`es it (and `/dev/uart.bluetooth`) to decide that a serial port exists
before it tries the IORegistry; `0386` keeps the node because that check comes
first, and the tty stays as the debugging path for the same engine.

`0399` registers the control and moves its bytes through the QUP wrapper 2
engine, with the same one-tick poll the tty used: 10 ms is 115 bytes at 115200,
under the engine's 128-byte RX FIFO, and RFR asserts before it fills. The
termios and the 12-byte UART option are accepted; the UUID names no nexus,
which is what selects the read/write fallback.

Nothing in `bluetoothd` can log, so the control and the tty print the first
packets in each direction (`MONDRIAN BTCTL:` and `MONDRIAN BTTTY:`). The tty
keeps eight; the control logs 64, because the daemon's init burst alone fills
an eight-packet budget and the scan traffic that follows never reaches the
ring. Those lines are the measurement: a `01 03 0c 00` from the daemon and an
answer from the part is the transport working. What comes after is the stack's
opinion of a ROM-only chip, which is where the firmware load enters.

With the Settings pane open, the daemon issues the classic inquiry
(`01 01 04 05 33 8b 9e 04 40`) and turns inquiry/page scan on (`01 1a 0c 01
01`); that is the scan the DEVICES spinner shows. A chip that answers the init
but never this command leaves the pane spinning with an empty list.

Before any transport, though, `bluetoothd` refuses to run without a local
Bluetooth address: every boot until now logged `exec bluetoothd` and
`exit bluetoothd ... status 0x0` a second later, and its job has
`KeepAlive = SuccessfulExit`, so a clean exit is final. Its
`FindLocalMacAddress` reads `kern.bootargs` for `wlan.debug.generate-mac` (or a
`wlan.factory=` whose low value has bit 2 set), then
`CFPreferencesCopyAppValue("SelfGeneratedLocalAddress",
"com.apple.BTServer")`; when that preference is missing it fills six bytes
from `arc4random_uniform`, stores `%02x:%02x:...` and carries on. The stock
root's `/private/var/mobile/Library/Preferences/com.apple.BTServer.plist` is an
empty dictionary, so the command line's token is the whole missing piece; the
board's command line carries it.

Measured 2026-11-19, that token moves the failure and does not remove it: the
same kernel prints `MONDRIAN BTTTY: /dev/cu.bluetooth major 19` at root mount,
and the boot's `bluetoothd` goes from `status 0x0` (no address, it exits before
any transport) to `status 0x100` (exit 1, restarted a few times) with the port
still never opened. With the job's stderr on a file that `rf` reads back, the
daemon says how far it gets and then stops:

```
com.apple.server.bluetooth: Bluetooth Super Server Robot Destroyer
could not find BT_DEVICE_ADDRESS env variable
marconi-bt: Unable to match bluetooth service in device tree.
marconi-bt: Not a valid MAC address (all 00s).
bluetooth: Unable to match bluetooth service in device tree.
bluetooth: Not a valid MAC address (all 00s).
FindLocalMacAddress found wlan.debug.generate-mac
FindLocalMacAddress Local address from plist:5d:75:0d:31:3f:87.
```

There is no "No valid serial port found" line, so the `access()` on
`/dev/cu.bluetooth` **succeeded**: the node is visible and the failure is after
it. The exit itself is silent, and the reason is the transport: `bluetoothd`
reads `BT_HCI_TRANSPORT`, and when the variable is absent it asks the
IORegistry for `marconi-bt` then `bluetooth` and falls back to **USB**, which
this phone does not have on that bus - so it exits before it opens anything.

The variable's format is `TRANSPORT:DRIVER[:PARAM]`, measured in the binary:
`0x1001561a0` `strtok()`s on `:` and matches the first token against the
transport table at `0x1007fd3e0` (`USB`, `H4DS`, `H4BC`, `H4`, `H5`, `APPLEBT`,
`VIRT`, `PCIE`, `PCIESW`) and the second against the driver table at
`0x1007fd430` (`USB`, `POSIX`, `APPLEBT`, `VIRT`, `PCIE`, `PCIESW`). `POSIX` is
the driver that opens a device path, and it is also the one the daemon probes
by hand: `access("/dev/cu.bluetooth")`, then `/dev/uart.bluetooth`, and only
then the `IOServiceNameMatching` calls. So the value to try is `H4:POSIX`.

`BT_DEVICE_ADDRESS` is not a lever: set, the daemon prints `Local address from
ENV:...` and then `Not a valid MAC address (all 00s)` / `No bluetooth on this
device`, exiting clean. The string it echoes and the address it parses are two
different reads, so the variable leaves the address zero and takes the
"no bluetooth" branch.

Two ways of listening to it do not work, both measured. `/dev/console` as the
job's `StandardErrorPath` leaves nothing in the dump while
`mondrianfb_noconsole=1`, so the ring does not carry userland console writes.
And `/private/var/vm` is not writable by the job's user, so launchd never
creates a log file there (`rf` answers ENOENT). `0387` adds
`rf PATH [OFFSET [LEN]]`, which reads a file back over the ring; with
`StandardErrorPath` under `/private/var/tmp`, `tools/usb-ring.py rf PATH OFFSET
LEN` is how the stack explains itself.

A `wfile` the filesystem refuses is silent in the client and reads like a
delivery: the host prints `N of N bytes delivered` from its own accounting, the
kernel creates the target with `O_TRUNC`, the write that follows fails, and an
empty file is what remains. Measured 2026-11-20: every upload answered
`MONDRIAN WFILE: <path> <n> bytes -> 28` (ENOSPC) with the root 22 MB from
full, and the dylib it was meant to replace stayed 0 bytes, so dyld had nothing
to load and the process it was injected into ran unchanged. Freeing that 22 MB
made the same upload answer `-> 0`. `tools/usb-ring.py` reads the kernel's
verdict now and reports a refused write as an error, and `MONDRIAN WFILE` in
the ring carries the errno either way; a 0-byte file the ring also answers with
`rf ... at 0: 0`.

Changing a job at all has its own trap, and it is bigger than a cache: launchd
does **not** read `/System/Library/LaunchDaemons/*.plist`. `launchd_cache_loader`
hands it the compiled table in `/System/Library/xpc/launchd.plist`, a binary
plist whose `LaunchDaemons` dictionary is keyed by the plist path
(`/System/Library/LaunchDaemons/com.apple.bluetoothd.plist` is the key for this
job). The individual plists are the build input, and editing one changes
nothing: measured, a job given a different `ProgramArguments` kept exec'ing the
old binary across reboots, even after unlinking and recreating the plist.

**The table itself stops the boot when it is edited.** Written with
`BT_HCI_TRANSPORT` and `StandardErrorPath` in the job, the boot stops at two
processes on both kernels: `launchd_cache_loader` reports `Cache sent to
launchd successfully`, launchd never prints its UUID or `Early boot complete`,
and SpringBoard never runs. Writing the image's own bytes back restores it.
`launchd_unsecure_cache=1` is what lets a table that does not match the image
load far enough to reach that point, so it is not a way to change a job. Two
more details make the writes hard to reason about: a shorter write leaves the
previous tail in place (`rf` past the end then still answers), and `del`, the
only way to start the file over, exists only on kernels that carry `0387`.

The variables therefore arrive at exec: `0388` gives `bluetoothd`
`BT_HCI_TRANSPORT=H4:POSIX` in its new process image, the same lever `0385`
uses for WebKit's GPU process, gated by `mondrianbt=1` so that no ordinary
boot changes. `0389` carries a dylib there instead of the literal, and
`tools/mondrian-bt.c` is that dylib: it sets the transport and the baud rate,
then claims descriptors 1 and 2 for a log file. The job runs as `mobile`
(`UserName` in its table entry), so its log lands in
`/private/var/mobile/Library/Preferences/mondrian-bt.log` and not in
`/private/var/tmp`, which its sandbox denies. Measured 2026-11-20, the file
carries the daemon's own startup:

```
mondrian-bt[882]: init uid 501 log "/private/var/mobile/Library/Preferences/mondrian-bt.log" transport "H4:POSIX" port access 0
com.apple.server.bluetooth: Bluetooth Super Server Robot Destroyer
...
FindLocalMacAddress Local address from plist:25:9a:f2:86:6e:39.
```

so the shim loads and the address is found. The next line is the next
process's `init`: the daemon leaves right after the address, before the
transport prints anything, and `_exit` runs no `atexit` handler - which is why
the shim interposes `_exit` and logs the status with the call addresses.

That log needs one more thing to be readable: `stderr` on a file descriptor is
block-buffered, and a process that leaves with `_exit` throws the buffer away.
Measured 2026-11-20, the file ended at the same line in every run, which reads
as "the daemon dies here" when it only means "the last 4 KB flush stopped
here". The shim sets `_IONBF` on both streams; a daemon's log that stops
cleanly at a message is worth suspecting of this before anything else.

The exit's backtrace names where it happens: `main` calls `0x100429030` with
the string `com.apple.bluetoothd`, and a non-zero answer there goes to the
restart helper (`0x100090734`, "Bluetooth error - restarting") through
`0x90778`. So the daemon is past the local address and into its own stack
startup, and the failure is that call's status - not the port node, which was
accepted by `access()` and never opened.

The messages that name it are `os_log` with runtime strings, so the shim
interposes `_os_log_impl` and its three siblings and writes the formats that
mention Bluetooth, transport, HCI or an error. Measured 2026-11-20, the last
lines before `_exit(1)` are the keychain:

```
oslog.error failed to update keychain data for device %{public}s with result %d. trying to add it now
oslog.error Failed to add attributes to keychain for device %{public}s with result %d. File a radar to Bluetooth (new bugs) | iOS
oslog.fault Failed to set new identity root!
oslog.error Failed to set new identity root!
```

So the transport is not what stops Bluetooth: the daemon cannot store its
identity root, and it treats that as fatal. The keychain itself is half there -
`securityd` runs and answers AKS requests, but selector 10 comes back
`0xe00002c7` (`kIOReturnUnsupported`) on every call (measured on the same
boot), which is the secure store this needs. Bluetooth is behind a working
keystore, not behind the UART.

A shim inside `securityd` cannot be used to see that decision: measured
2026-11-20, the kernel injects the variable (`MONDRIAN exec: injected
securityd log` in the ring) and the loader ignores it - the full shim and a
15-line constructor with no interpose section both leave no file, while the
same boot loads the Bluetooth shim into `bluetoothd` (`mondrian-bt[85]: init`).
Instrument the client that does load, or the database, not `securityd`.

That selector is `kAKSWrapKey`: the class keys the keychain keeps are wrapped
with the device key, which on hardware lives in the SEP. `0391` answers it, and
`kAKSUnwrapKey` with it, from the kernel's own store (the blob is eight bytes
longer than the key, the shape AES key wrap has). Measured on the boot after:
both selectors answer `0x0`, `securityd` keeps the keychain and calls nothing
else on that path, and `bluetoothd` runs to its next failure instead of dying at
the first keychain call.

That next failure is still the keychain: `failed to update keychain data ...
result -25300` (item not found, expected) is followed by `Failed to add
attributes ... result -25291` (`errSecNotAvailable`). Measured 2026-11-20 with
the `0396` open trace, `securityd` reaches the database and the creation fails
for lack of space:

```
MONDRIAN OPEN: securityd /private/var/Keychains/keychain-2.db flags 0x9000102 -> 2
MONDRIAN OPEN: securityd /private/var/Keychains/keychain-2.db flags 0x9000100 -> 2
MONDRIAN OPEN: securityd /private/var/Keychains/keychain-2.db flags 0x9000302 -> 28
```

`2` is `ENOENT` and `28` is `ENOSPC`; the third call is the one that creates
the file. The volume says why: `MONDRIAN HFSAUDIT: total 4194304 counter 0
bitmap 574 diff 574` - the free-block counter is zero while the allocation
bitmap still has 574 blocks (2.3 MB), and `hfs_block_alloc_int` refuses every
allocation while that counter is zero, so every write that needs a new block
fails. `UMD_INIT` cannot write `/private/var/keybags` for the same reason
(`No space left on device`). `0397` adopts the bitmap count at mount, because
the bitmap is what actually says which blocks are free.

The 2.3 MB only cover the file's first page, and the volume is full again by
the time the rest is written. The 21.8 MB that `/private/var/vm`'s `m2v_test`
and the GPU probes held proved the gate from the other side: two consecutive
boots with that space keep one `exec bluetoothd` and **no exit**, and the
Bluetooth log goes from `Failed to add attributes ... -25291` and `Failed to
set new identity root!` to no add error at all: the database is written (its
first page in `keychain-2.db`, the rest in `keychain-2.db-wal` until
checkpoint), and the queries that remain return `-25292`
(`errSecInteractionNotAllowed`), which the daemon survives. The volume is the
gate, not `securityd` and not the AKS class.

`0398` removes the gate. The root is a 16 GiB image inside `userdata` (223.6
GiB on this unit) and HFS administers only the blocks the volume header names;
the patch lets `hfs_extendfs` run on the unjournaled root, arms it from the
read-write upgrade the userland performs, and grows to the device from a thread
call one second later. The UFS driver reports a device that ends before the
console ring, so the volume cannot allocate over it. Measured 2026-11-20: the
extend went from 4,194,304 to 58,615,226 blocks (223.61 GiB) on a boot whose
bitmap had zero free blocks, and the next boot's audit read `total 58615226
counter 54400880 bitmap 54400880 diff 0` - about 207.5 GiB free, with the
keychain database and the BT dylibs still in place.

The seeded-database reading was this cause seen from the other side: the file
was readable while it existed, and the next boot started without it (measured);
with no block for its journal, that is what the failed open leaves behind
(expected). It is the volume, not a decision inside `securityd`, and not file
ownership: the job runs as `_securityd` (`com.apple.securityd.plist` sets
`UserName`) and the root images are installed **noowners**.

The selector answers had been the problem before that. `kAKSWrapKey` takes two
scalars - the bag and the **protection class** - and returns one: the class the
item must be stored under. This answered with the wrapped length, so every item
went in under a class that does not exist and the add failed with a database
that was fine. The class also belongs in the blob, and the device state has to
say what this device is: `ss` bit 1 (no passcode) and lock state 3, "disabled".
Reporting a plain unlocked state instead makes the caller look for a passcode
keybag that is not there.

That shape comes from `oosexgang/hackios-xnu-kernel`'s `MiniAppleKeyStore`, which
reports a working keychain for exactly this fixed situation (no passcode, never
locked, unlocked since boot) and carries the same eight-byte overhead, the
notification port, `GetBagUUID`, `GetConfiguration` and `Generation`. `0392`
mirrors it. The keychain's class keys are therefore not a reason to build a real
keybag: a reversible wrap is enough, which is what that reference says it uses.

With `0392` and the database that boot already had, the daemon stopped dying:
measured 2026-11-20, one `exec bluetoothd` and **no exit** for the whole boot,
`kAKSUnwrapKey` answering `0x0` where the old-format blobs had answered
`kIOReturnBadArgument`. Deleting that database to clear the old format does not
rebuild it while the volume cannot allocate a block (above), so the boot after
the delete dies again: the wrap is no longer what blocks the daemon.

What is left on this front is the transport: the daemon now reaches its HCI
configuration and the port node is opened by hand between boots, but nothing in
the log says it opened `/dev/cu.bluetooth`, and the SM8475's controller is not
behind that tty yet.

There is **no shell on this root**, so a job cannot be wrapped in `sh -c`:
launchd refuses the spawn, and its own error does reach the ring as
`com.apple.xpc.launchd ... <Error>: Missing executable detected. Job:
'com.apple.bluetoothd' Executable: '/bin/sh'`, which makes that channel the
place to look when a job silently does not run. The redirection therefore has
to be a job key (`StandardErrorPath`) rather than a wrapper.

### The switch, the scan and the daemon's exit chain (measured)

The Settings switch reaches the app, not the controller. Measured 2026-11-21
with the pane open: a 120 ms drag on the switch raises iOS 16's "Turn off
Bluetooth?" alert, so the action does run. While the daemon was still exiting
every 16 s, confirming **Turn Off** left the title dimmed and a spinner where
the switch was, while the HCI Inquiry kept its cadence without a gap (… 2389,
2405, 2422, 2438, 2454 s); the model changed and the radio did not. That
symptom was the restart cycle below, not the switch.

`bluetoothd` used to exit with status 1 about every 16 s; each refused HCI
command is fatal to it, and its plist (`KeepAlive.SuccessfulExit=false`) makes
launchd restart it, so every restart ran the full HCI init and wiped the device
list. Three separate chains fed that loop, all measured 2026-11-21:

- The Olympian vendor commands 0xfce9/0xfce2 are answered in the kernel control
  (`mondrian_btctl_send`, `0399`), not in the user-space shim: a shim reply
  waits in its own buffer until the daemon reads again, and the daemon waits
  for the socket to become readable, so the command timed out anyway.
  `ctl_enqueuedata` makes the socket readable; 0xfce2 carries two zero bytes,
  the smallest payload the Broadcom parser accepts.
- The controller's FIFO carried a reset completion the previous daemon never
  read, and the next daemon took it as the answer to its own reset: the stack
  exits on a completion it did not ask for and leaves its own behind, so the
  chain never ended (the exit report named `OI_DHCI_RESET_OPCODE`, and one read
  held two identical completions). The connect path drains the FIFO, and the
  poll resynchronises on the H4 packet type: the controller emits 0xFD/0xFE
  wake filler between packets and answers the shim's 0xFD wake with a bare
  0xFC, so only the filler is dropped.
- With the FIFO clean, the reset still went unanswered: the part was in HCI-IBS
  sleep, repeating 0xFD every 100 ms and taking no command until the host
  answers 0xFC (`hci_qca.c`). The shim answered during `qca_boot` and nobody
  did afterwards. The poll answers now, under a write lock shared with the
  daemon's commands.

Measured after those: one `bluetoothd` pid for minutes, zero `exit
bluetoothd`, `ibs ack` counted in the ring, and the Settings row showing
Bluetooth **On** with the switch drawn.

The Settings switch is fixed. The drag reaches UIControl (the bridge probe logs
`switch action controlChanged: -> PSSwitchTableCell`), and the teardown that
follows calls the transport's notify slot at `+0x60` with a bare `br x0`
(bluetoothd `0xf3b4c` calls `0xe6aac`, which loads `[transport + 0x60]`).
Apple's H4 table leaves that slot NULL -- the APPLEBT and H4BC tables fill it
with a stub that sets a state byte, and H4 has no such byte -- so the call
landed on address 0: `sig 11 pc 0x0 far 0x0 lr bluetoothd + 0xf3b50`. The shim
now puts a no-op in the empty slot at startup (`h4: notify slot +0x60 was NULL,
no-op installed` in the power log). Measured 2026-11-21 on a live pane: a drag
off shows the powered-off text ("AirDrop, AirPlay, Find My, and Location
Services use Bluetooth"), a drag on brings back the discoverable text and the
device list, and one pid serves both. Control Center's Bluetooth button is
separate: on iOS 16 it only stops new connections ("New Bluetooth connections
have been turned off from Control Center") and keeps the pid.

The LE scan is the control's translation. bluetoothd asks for the legacy pair
because its init-time report says `enableExtendedScanHCI=0`, and the WCN7850
refuses 0x200b/0x200c with 0x0c in every state. `0399` rewrites them to
0x2041/0x2042, answers the daemon with the completion for the opcode it sent,
keeps one pending completion per translated command (a flag let a back-to-back
enable/disable completion reach the daemon, which exits on an opcode it never
sent), and turns every extended advertising report (subevent 0x0d) into the
legacy report (0x02) the daemon parses. The own address type is forced to
public: bluetoothd asks for random, and the controller answers the extended
enable with 0x12 when no random address is set (probe: own=1 -> 18, own=0 -> 0,
same interval, window and filter).

Measured on the live pane: reports arrive (`ext report
c8:a6:ef:12:00:9f type 0x0013 data 31`), the pane lists
`C8:A6:EF:12:00:9F` and `B0:AC:82:15:22:3C`, and the air carries names: the
probe decoded `51:69:9b:35:ed:46 name "ASUS-TUF-GAMING"` from a scan response,
`C8:A6:EF`'s scan response carries the shortened `55" Crys` and its classic
EIR a complete `10 09 35 35 ...`, and `B0:AC` is classic-only with
`09 09 44 49 47 49 20 52 32 41` = "DIGI R2A".

The daemon does not use any of them. `kCBMsgIdDeviceGetNameMsg` answers
`kCBMsgArgResult 212` and a zero-length `kCBMsgArgName` for every row, with a
fresh daemon and a fresh Settings client (measured 2026-11-21), so the pane
draws the address. The control bridges the gap for LE devices: it searches the inquiry response
for a name structure (0x08 or 0x09, after the firmware's junk prefix) and
appends it as a Complete Local Name to the LE report for the same address,
translated 0x0d or the legacy 0x02 the controller also sends, when the
advertisement carries none. A shortened name (0x08) in a report is
promoted to the complete type (0x09), because the daemon reads only 0x09 and
the controller's scan responses carry 0x08. A classic-only device has no LE
report to carry the name; `B0:AC` stays on its address until the daemon uses
the EIR.

The name is on the stream the daemon reads, so the loss is inside it. Measured
2026-11-21: the pane's own scan is active when it asks (`scan params type 1 own
1 filter 0`; a background scan asks type 0), the controller answers with scan
responses (`ext report ... type 0x001b data 17`), and the control's legacy
conversion promotes their 0x08 name. A framer in the shim's `read` path logs
every name it sees in that stream (`adv name` in `mondrian-bt-power.log`):
`ASUS-TUF-GAMING`, `[AV] Samsung Soundbar MS650`, `RGB smart bulb`, `Dryer`,
`[TV] Samsung 5 Series (49)`, `LUH-D301S-WEU`, `X2+ Connect_D54EABA568E6`.

The daemon's discovery depends on the controller's own address. The WCN7850
ships unprovisioned and answers Read BD_ADDR (0x1009) with QCA's default
`00:00:00:00:5A:AD`, the value in NVM tag 0x0002 and the one Linux's btqca
calls `QCA_BDADDR_DEFAULT`. With it, Create Connection (0x0405) is rejected
with Command Status 0x11 "unsupported feature or parameter value" (measured
with a DM1-only packet type mask, 0x0001) and the pane's rows stay bare
addresses. The shim provisions the controller in `qca_boot`: it reads 0x1009,
and when the value is the default it writes `02:00:00:00:5A:AD` with
`EDL_WRITE_BD_ADDR` 0xFC14 and reads it back. The command takes the address in
**display order** (the stock HAL swaps `GetLocalAddress` into that order;
sending HCI order stored the reverse) and refuses a second write with status
0x02, so a provisioned controller is left alone. The value survives a reboot.

With a valid address the pane's own path discovers devices: it still answers
`_stackClassicScannerShouldRun` 0, but its scan sends Inquiry
(`hci req 0401 len 9`) and the controller accepts it. The answer is a
**Command Status** (`hci cs 0401 status 0`, event 0x0f), followed by Inquiry
Complete (`inquiry complete status 0`), not a Command Complete; an earlier
framer reset on every event code but 0x3e and the probe looked for 0x0e, which
is why the controller looked silent. The pane then lists the PC
`A8:41:F4:2C:C2:35` and the Digi `B0:AC:82:15:22:3C` without any forced
scanner.

The row's action works now. A tap on the row queues Create Connection (`hci req 0405 len 17` with packet-type mask
`18 cc`, Command Status 0) and the controller answers
`conn complete status 0 handle N ... link 1`: the link to the PC comes up.
The tap is at the row's centre (panel `720 880` on this layout); a tap above it
does nothing, which is why earlier probes found the row inert.

The daemon then asks for the name: `hci req 0419 len 14` with ten parameters
(`35 c2 2c f4 41 a8 01 00 <clock>`: address, page-scan repetition mode,
reserved, clock offset). An earlier revision of the control appended an
eleventh byte, and the WCN7850 answered every request with Command Status
0x12 (Invalid HCI Command Parameters): the name never arrived. The command is
now forwarded unchanged and the controller answers
`rnr complete status 0 a8:41:f4:2c:c2:35 "ASUS-TUF-GAMING"`. The name arrives
after the pane has already built the row, and the daemon's own name reply
stays empty (`kCBMsgArgResult 212`), so bluetoothd does not apply it to the
device object. The shim bridges it the same way the control bridges EIR names:
it remembers every successful 0x07 and writes `kCBMsgArgName` into the outgoing
event that names that address (`name.inject`), then answers the client's
follow-up 212 with the same name and result 0 (`name.reply`). The pane draws
`ASUS-TUF-GAMING` instead of `A8:41:F4:2C:C2:35` (measured 2026-11-21).

The resolved name is persisted in
`/private/var/mobile/Library/Preferences/mondrian-bt-names`, because bluetoothd
restarts on stack errors and the RAM-only cache left the pane on the bare
address (`A8:41:F4:2C:C2:35`) until the row was tapped again. Measured
2026-11-22: restart the daemon, reopen the pane without touching the row, and
the row draws `ASUS-TUF-GAMING` from the file.

Pairing completes when the PC starts it. Measured 2026-11-22: in Windows,
Settings > Bluetooth y dispositivos > Agregar un dispositivo > Bluetooth and
then a click on the device item ends with "Conectado", and
`DeviceInformation.Pairing.IsPaired` reads true while the controller logs
`link key notify`. Windows refuses the phone's own attempt: `BTHUSB` event 16
("Error en la autenticacion mutua") and 37 ("Se rechazo una solicitud de
autenticacion entrante") appear when the pairing starts from the row tap, so a
row tap alone cannot pair.

The pairing that counts is the one Windows answers. With its "Emparejar
dispositivo" prompt open, clicking Permitir completes it and the controller
reports the whole handover: `pair evt 36 plen 7: 00 <addr>` (Simple Pairing
Complete, status 0), `link key notify <addr> type 4` and, from the shim,
`link key stored <addr> type 4 slot 0`. Without that click the controller never
reports 0x36 and no key exists anywhere.

The controller runs Secure Simple Pairing with numeric comparison either way:
`pair evt 31` (IO Capability Request), the host's 0x042b reply, `pair evt 32`
carrying the remote's `01 00 05` (DisplayYesNo, MITM required), then `pair evt
33` with a six-digit value. 0x33 is User Confirmation Request, not a passkey
notification, and the host must answer 0x042c; the shim does
(`pair confirm <addr> value 507960 -> 10`), the same result as pressing Pair.
Without it the controller repeated the event up to three times with a fresh
value and bluetoothd dropped the link with reason 0x16.

Just Works is not reachable from the host. The daemon's 0x042b carries 0x01
(DisplayYesNo); the shim rewrites it to 0x03 (NoInputNoOutput) and clears the
MITM bit (`io cap 01 oob 00 auth 04`, then `io cap rewritten to 03 auth 04`),
and the controller still runs numeric comparison because the remote asked for
MITM. An earlier note that the rewrite "made no difference" was reading a log
line: `my_write` sent the original buffer.

The pairing is not durable and the app never learns about it. The controller
keeps no key of its own: before a completed pairing exists it asks the host
(`link key request a8:41:f4:2c:c2:35`), bluetoothd never answers, and the link
falls back to a fresh pairing in the same daemon session (`pair evt 31`,
`io cap`, `pair evt 32`, `pair confirm`). After a completed pairing the next
connect starts 0x31 again with no request at all, so the request only appears
once the controller has forgotten the key. `tools/mondrian-bt.c` keeps the key
the controller reports (`link key notify`) in
`/private/var/mobile/Library/Preferences/mondrian-bt-keys` and answers the
request with 0x040b (`link key reply ... -> 26`).

Measured 2026-11-22, after the Windows device record was deleted and the PC
paired again: the tap produced `link key request` and the shim's stored key
(`link key reply a8:41:f4:2c:c2:35 -> 26`), and the next lines from bluetoothd
carry a *new pid* - the daemon restarted instead of carrying the link, and
Windows reported the connection failed while `IsPaired` stayed true. A key at
the controller is therefore not enough: the daemon needs a device record of its
own, and only its pairing client creates one. That client is `CBConnection`,
only exists through `initWithXPCObject:error:` from its activation message:
`alloc`/`init` plus `addPairingClient:error:` restart-loops bluetoothd (the pid
climbed 1646 -> 1650 -> 1658 within a minute) and must not be repeated.
`addPairingClient:error:` and `pairingContinueWithPairingInfo:error:` are never
called, neither `_xpcCBConnectionActivate:` nor the `_xpc*` device handlers
fire, and no outgoing XPC carries a prompt.

A boot whose kernel is older than the Bluetooth injector has no Bluetooth at
all: `bluetoothd` execs and exits with status 0, the shim never writes its
`init v63` line, and Settings hides the Bluetooth row. Check the ring's
`Darwin Kernel Version` against the kernel just built before reading anything
into a missing row or a missing probe line.

The row tap sends bluetoothd nothing, and the app side is not reachable with
the picture bridge. Two attempts, both measured 2026-11-22: an XPC interposer
compiled into `mondrian-layer-bridge.dylib` (the only dylib every app receives)
left Settings painting a solid red window, and a probe that walked the
`CBConnection`/`CBManager`/`CBStackController` method lists and swizzled
`connectDevice:connectionFlags:serviceFlags:error:` made Settings crash on every
launch (`CRASH Preferences sig 11`, before its first frame). Both are reverted;
the bridge is back to the committed build. What the row tap calls inside
Settings is still unmeasured, so the next attempt needs a mechanism that does
not touch the shared bridge: a hook the kernel injects into Preferences alone,
or a breakpoint on the daemon side of the XPC service it should be talking to.

The connect is tap-driven: with the pane open and the PC in the list, no
`hci req 0405` appears until the row is tapped, and then it follows within
seconds. The ObjC controller is not the path: both
`connectDevice:connectionFlags:serviceFlags:error:` and
`connectWithCBConnection:completionHandler:` are replaced with logging
implementations and neither is called for that connect, so the request goes
through the BTStack object below the controller.

The controller's Inquiry Result is malformed at the source: `plen` is 0xff
(258 bytes) and the bytes between the 13 fixed fields and the EIR are not
cleared (`e4 c0` repeats for the PC; one or three junk bytes precede
`09 09 DIGI R2A` and `10 09 ASUS-TUF-GAMING`). Rebuilding the event into the
fixed fields plus the EIR chain made the daemon stop creating devices, so the
control forwards it unchanged; the name search only feeds the LE bridge. A
classic-only peer therefore stays on its address until the daemon itself asks
for the name, which is the next gap.

The shim's log is `/private/var/mobile/Library/Preferences/mondrian-btd.log`
(truncated on each start). The `_exit` interposer writes
`mondrian-bt-exit.log` instead, truncated on every exit so it always holds the
newest one: status, x19/x20 resolved as text, a backtrace, and the last 16 HCI
writes and reads with their bytes. That ring is what identified 0x200b -- the
kernel's own packet log keeps only the first 64 packets of a connection
(`MONDRIAN_BTCTL_LOG_PACKETS`), so it had shown the start of a run, not its
end.

The power log is different and is capped: it is append-only and took one line
per Inquiry Result, so by 2026-11-22 it had reached 5.4 MB in a day. Nothing
reads it wrong; the cost is that a pull is one 1000-byte request per block, and
an offset past the end answers zero bytes, which reads as an empty log instead
of as the end of one. The shim now caps the file at 1 MiB (`BT_POWER_MAX`,
truncated with a `log rotated` marker), logs the first four results of a scan
and the total on Inquiry Complete, and `tools/wsl/bt-read-log.sh` pulls from
offset 0 and stops at the first short answer.

`usb-ring.py pos` is **not** a file size: it prints the ring's byte count and
ignores a path argument. Reading `pos` as the log's length makes a pull start
past the end and come back empty; the length comes from the pull itself.

Reproduce: `tools/wsl/verify-bt-stable.sh` opens the pane and compares two
dumps a minute apart (one pid, no new exits, the three answers counted);
`tools/wsl/verify-bt-power-cycle.sh` drags the switch, confirms Turn Off and
prints the Inquiry seconds around it; `tools/wsl/trace-bt-power.sh` prints the
transport and init events after the drag marker;
`tools/wsl/probe-switch-actions.sh` logs UIControl actions through the bridge
probe at `/private/var/vm/bridge-switch-probe` (the action line can precede the
kernel's touch marker, so do not read the two as ordered);
`tools/wsl/bt-job-info.sh` prints the plist keys, `tools/wsl/bt-exit-reason.sh`
rebuilds the shim, deploys it and prints the newest exit report,
`tools/wsl/bt-last-hci.sh` shows the last HCI exchange before an exit,
`tools/wsl/bt-ext-probe.sh` runs the extended-scan matrix and decodes the names
in the reports it receives, `tools/wsl/bt-name-check.sh` opens Settings >
Bluetooth and prints the scan counters, the names the control injected, the
daemon's `kCBMsgArgName` replies and the decoded LE/classic names,
`tools/wsl/bt-name-reply.sh` restarts bluetoothd and SpringBoard and prints the
name replies with a fresh client, and `tools/wsl/bt-read-log.sh PHONE-PATH`
pulls any of the append-only logs (`bt-power.log`, `bt-exit.log`).

## What other ports teach

| Project | What it does | Lesson for mondrian |
| --- | --- | --- |
| [itlwm](https://github.com/OpenIntelWireless/itlwm) | Intel WiFi as an `IOEthernetController` plus the HeliPort app | A fake Ethernet interface plus a userland supplicant works without `IO80211`, but there is no native Wi-Fi UI |
| [AirportItlwm](https://github.com/OpenIntelWireless/itlwm), [SimpleMtkWlan](https://github.com/pengubow/SimpleMtkWlan), [AirportWCN7850](https://github.com/razvanccr/AirportWCN7850) | Implement `IO80211Controller`/WCL on top of Apple's family | Native menu achievable; version-sensitive; **AirportWCN7850 is the closest precedent**: a Qualcomm WCN7850 (same MHI/QMI/WMI generation as our WCN6855) working at 11ac |
| [BluetoothWCN7850](https://github.com/razvanccr/BluetoothWCN7850) | QCA firmware loader kext; Apple's userspace stack drives HCI afterwards | The proven pattern: load firmware at match time, before userspace can seize the device; read the status bits and send only what is missing |
| [IntelBluetoothFirmware](https://github.com/OpenIntelWireless/IntelBluetoothFirmware), [BrcmPatchRAM](https://github.com/acidanthera/BrcmPatchRAM) | Firmware loaders for other vendors | Same pattern; the stack does the rest |
| `BlueToolFixup`, `IntelBTPatcher` | Patch `bluetoothd` transport selection/vendor list; fix LE scan address | Apple's transport choice and vendor whitelist are the real gate, not the HCI link |
| Project Sandcastle (Android on iPhone) | The reverse port | Even there, Bluetooth, GPU and cellular were never brought up: radios are not a shortcut |

Concrete traps paid for by those ports, all relevant here:

- `AirportWCN7850`/`BluetoothWCN7850` bring-up notes: `IOCommandGate::runAction`
  passes the gate's owner; `mbuf_pullup` always splits a cluster mbuf; the
  WCN7850 reaches only the first 4 GB (bounce buffers); one MSI vector is
  enough, but its CE interrupt mask must be set; the vdev is created on the
  first interface-up.
- AWDL/AirDrop is not coming on a Qualcomm fullMAC: the firmware owns channel
  timing, and it has no AWDL engine
  ([feasibility study](https://github.com/razvanccr/AirportWCN7850/blob/main/docs/awdl-feasibility.md)).
- The Bluetooth loader must run before `bluetoothd` enumerates the transport
  (kext matching does this; a launch daemon loses the race), and firmware held
  in RAM does not survive a power cycle.

## What is next

Bluetooth is done: the controller, the RAM patch/NVM and the tty (`0386`,
`0388`) work, and a pairing started from the PC completes. A2DP still waits for
an audio route: `MONDRIAN TONE: play 0 duration 1.00 route` returns an empty
route, and the choice between a virtual `AudioServerPlugIn` and a codec driver
is still open.

Wi-Fi is the remaining half, and it needs a decision made up front:

- The driver work is PCIe enumeration (PERST, wake, clocks) → MHI → QMI
  (`cnss2`) → `ath11k` WMI (scan, join, keys). The `qwz` port in
  `AirportWCN7850` is the map for the macOS side; our chip is `ath11k`, not
  `ath12k`, so the Linux driver is the reference.
- The userland interface is the fork in the road. **(a)** Implement the
  `IO80211SkywalkInterface` surface `wifid` matches, giving the real Wi-Fi
  menu; this is the expensive path. **(b)** Give iOS an IP interface (a
  custom `ifnet` or `utun`) fed by a userland supplicant; connectivity works,
  the Wi-Fi menu does not.
- Do not plan on AWDL/AirDrop either way.

Estimate from the precedents: Wi-Fi with the native interface is six to twelve
months of driver and compatibility work, and the IP-only path is shorter but
still needs the full firmware/MHI/WMI bring-up first.
