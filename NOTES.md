# ios-mondrian — engineering notes

Port of [ios-sweet](https://github.com/dipa-studio/ios-sweet) to the **POCO F5
Pro / Redmi K60** (`mondrian`, Qualcomm SM8475 / Snapdragon 8+ Gen 1): Apple's
open-source XNU (xnu-8796, the iOS 16 generation) running the unmodified
iPhone X iOS 16.7.16 userland.

This file holds the state of the port and the facts that were expensive to
learn; the work list, the hardware delta and the partition rules are in
`docs/MONDIAN_PORT.md`. The upstream `sweet` port is the reference
implementation and is not re-described here: `xnu/patches/` is its record.

## State (2026-11-25)

- **Boot chain.** ABL → `fastboot boot` (or the `boot_b` image) → shim → XNU.
  The shim reads the live device tree, unpacks the LZ4 payload and jumps. The
  console draws into the splash framebuffer the ABL leaves at **0xB8000000**
  (1440x3200, stride 5760). Build with `SMALL_SHIM=1`; why is in the shim trap.
- **Fastboot, and the only way back to it.** `fastboot devices` answers in the
  bootloader's fastboot (power + volume down); fastbootd refuses `fastboot boot`.
  ABL allows seven `slot-unbootable:b:yes`; `fastboot set_active b` resets them.
  From iOS the ring's `reboot` writes the BCB with raw blocks, then the PMK8350
  restart reason on its own thread, then PSCI; `hardreset` is that minus the
  HFS sync. ABL reads the reason, so a BCB alone boots the active slot, and a
  reset whose reason write stalls lands on `boot_b`. Both mappings that write
  needs -- IMEM and PMIC SDAM -- are taken at boot (`0466`, `0468`); doing
  either inside the reset deadlocked behind a wedged driver.

  **`boot` can be refused while `Sending … OKAY` prints:** require `Booting … OKAY` and no `FAILED`; `tools/wsl/flash-image.sh` checks the slot first.
- **Kernel.** Reaches `bsd_init` through `arm_init`, VM init, IOKit, scheduler and AMFI; GIC/vtimer fixes (`0116`, `0173`) are in the traps.
- **UFS, end to end.** Host clocked, NOP/QUERY answered, the LU woken, the GPT
  parsed, `userdata` located, HFS+ root mounted and `launchd` exec'd. `0398`
  grows the 16 GiB volume to `userdata` (223.6 GiB here); the 4 MiB ring at the
  end of the partition stays outside it.
- **USB, both directions.** `usb=1` probes the DWC3 the ABL leaves powered;
  `usb=2` runs the gadget: an ECM device at 192.168.7.2, control on udp/5141.
  `tools/usb-ring.py` dumps the ring, photographs the panel, injects input and
  reboots to the bootloader. `tools/ios-usbnet.sh` sets the host up, NATs the
  link and streams udp/5140; names resolve only once the hook publishes
  `State:/Network/Service/mondrian-usb/{IPv4,DNS}` in configd's store -- iOS
  never reads `/etc/resolv.conf`. A cold boot now enumerates: `0312` makes the
  DWC3 reset (PHY powered, PIPE clock from UTMI) and `0313` votes the eUSB2
  repeater's rails; it answers nothing on i2c5 even when powered, and
  `mondrianusbfallback=N` returns to fastboot. This core has one RX FIFO per
  OUT endpoint; depth 0 NAKs every packet (`GRXFIFOSIZ`, `DEPCFG`).
- **Clock and zone.** The PMK8350 RTC (SPMI PPID `0x61`) belongs to another
  processor (owner 4), so a write is refused: `mondriantime=<seconds>` seeds the
  date and `rtc set SECONDS` moves the clock (`0315`); the hook repoints
  `/var/db/timezone/localtime` and resets `NSTimeZone`.
- **iOS userland.** `0089` handles root-auth ENOTTY; launchd reaches 150
  processes and `0112` injects the UI dylib per daemon. `0090` adds WRITE(10);
  `DKIOCISWRITABLE` must agree or HFS disables writes. Settings, Messages,
  Photos and Safari launch; the VADC battery level works (`docs/MONDIAN_POWER.md`).
- **Display and UI.** The home screen and Settings draw on the 1440x3200 canvas
  (120 Hz); CoreAnimation composites through Mesa/freedreno FD725 on the Adreno
  730 (home 81-87 fps, scroll 113-118) in place (`docs/UI_PERFORMANCE.md`).
- **Video.** `0420` loads `vpu20_4v.mbn` through PAS 9 and accepts the iris2 data path: properties on their ports, BIN/LINE/COMV/NON_COMV before `START(1)`, DPB/raw after `START(2)` (both `flags=0x1`); firmware 2.4 marks `COMV_BUFFER_COUNT`, `OPB_ENABLE` and `PARTIAL_DATA` unsupported (info only). A 128x128 HEVC Main sample parses and answers `SETTINGS_CHANGE`; V19 (whole-batch `wait_session`) still returns raw 0 with `LAST`/`data=0`, and the raw port's `SETTINGS_CHANGE` arrives after the frame, so output reconfig is next.

Current blockers, in order:

1. **Wi-Fi link, SMMU, MHI and BHI proven; the firmware is next.** W1 reaches
   Gen2 x1 and QCA6490 ID; W2 programs bank 74/SID `0x1c01`; W3 assigns BAR0
   and proves bus master; W4/W5 read MHI and BHI 1.2. The BHI image load is
   the open question; QMI/ath11k and camera remain absent.
2. **Metal is partial.** Metal2Vulkan passes blit/clear tests. WebKit's GPU
   and WebContent hooks fire but still allocate `w30r` surfaces and paint
   black; the Gestalt interposers are never called, so 8-bit is not the
   selector (`docs/REFERENCE_FINDINGS.md`). The UI composites through Mesa GLES.
3. **Haptics: kernel half is whole, iOS half is not.** `/dev/mondrian-haptic`
   (`0511`, `major 20 node ok`) coalesces HAL frames into a PM8350B buzz, but
   no iOS client has opened it. Direct SPMI play lifts the boost and programs
   `0x498`, yet long tones moved nothing; `hapclick` stages the DT's click.
4. **Brightness.** The panel takes the DCS write (`0305`); the iOS slider moves nothing (`docs/MONDIAN_POWER.md`).
5. **Stability.** Reflashing `backup/ios-root.simg` and deleting VirtualAudio
   removes the mediaserverd crash loop (`crash 2`, zero crash lines); large
   `wfile` uploads damage HFS again. `bluetoothd` still dies twice per boot
   with `sig 6` after HCI traffic; a warm reboot can leave the boot core
   unstarted (`docs/MONDIAN_GPU.md`).

## Building and booting

**Kernel.** `.github/workflows/xnu.yml`, `tools/build-kernel-local.sh` (Mac) and
`tools/wsl/build-kernel.sh` (Windows/WSL2, `docs/BUILD_LINUX.md`) fetch
xnu-8796.141.3, reset the checkout and apply `xnu/patches-mondrian/`; a skipped
patch fails the run. **The workflow cannot run on this repository since
2026-11-17**: every dispatch is cancelled within seconds with "The
configuration 'macos-14-arm64-us-default' is not supported" (`gh run view`), so
a green `gh run list` is not the thing to wait for -- build with
`tools/wsl/build-kernel.sh` and flash that. Run `tools/apply-series.py` (or
`tools/check-patches.sh`)
after touching the series: it names the patch in seconds (`0161` was silently
missing until 2026-10-28, `0157` carried its first hunk). **The series is the
only source of truth:** a build whose hash changed resets that checkout, so a
driver edited there and never exported is lost (the DSI brightness driver went
that way on 2026-11-11). A mondrian build also needs the local
`mondrian_gmu_fw.h`; `0184` stubs the user-client surface without the CP
profile.

**Apple's clang builtins are load-bearing.** Without `__builtin_xnu_type_*`
(`tools/wsl/patches/0002` stubs them) every kalloc_type view is a data view, none
is kept, the iterator that follows asserts (`kalloc.c:1264`) inside
`kernel_bootstrap` (black panel, no ring), and `0008` returns when none was kept.
A newer Xcode's `iig` also regenerates the DriverKit stubs wrong; seed them from
a build made with Xcode 15 (`docs/MONDIAN_GPU.md`).

**Image and deploy.** `tools/phone-boot.sh` builds if needed and boots
volatile; `tools/phone-deploy.sh` (push/install/backup/reboot) is the adb path
and refuses `boot_a` unless `BOOT_A=1`; `tools/qemu-ios.py` boots the same
payload (`docs/QEMU_TESTING.md`).

**Reading a boot.** `0096` tees kernel and `/dev/console` output into a 4 MiB
ring that `0174` arms before `vfs_mountroot`, and the same ring is the last 4 MiB
of `userdata` behind a `MONDLOG` header, so a boot with no USB still has its log.
`tools/usb-ring.py dump` reads the live ring and `screen` captures the panel
(`usbipd attach --wsl` first; `0298` survives a detach). `prev` prints the
*previous* boot's newest lines (`0329` copies that area into RAM before this
boot's first flush), and its window is the *reader's*: `mondrianprevlines=N` goes
on the boot that reads, because the next boot's flush overwrites the dead area,
and a chatty writer (the iOS-side net script repeating `default route ... err
17`) pushes the lines out of a small window — a wedge followed by a quiet reader
needs `N` in the thousands. `mondrianstop=N` halts at early mark N (`0174` keeps
marks
above 20 visible once the console is off) and `mondrianreset=N` is a second
clock: a boot that ends at about 45 s is that thread rebooting to fastboot.

## Measured hardware facts

From the live device tree (and from the shim's own dump):

| what | value |
| --- | --- |
| `/memory` | `0x80000000+0x6a000000`, `0xf4600000+0xba00000`, `0x837b00000+0x1e00000`, `0x800000000+0x37500000`, and `0x840000000+0x240000000` as two adjacent regions (9 GiB, no reservation inside) |
| RAM the bootloader offers the kernel | ~1.85 GB (`ddr_size` claims 12) |
| hole that is not RAM | `0xea000000..0xf4600000` |
| `/reserved-memory` | 38 carve-outs: hypervisor `0x80000000+0x600000`, AOP, SMEM, modem `0x8bc00000+0x13200000`, splash `0xb8000000+0x2b00000`, tags, QTEe |
| framebuffer | `0xb8000000`, 1440x3200, stride 5760, 43 MiB |
| GICD / GICR | `0x17100000+0x10000` / `0x17180000+0x200000`, 8 redistributors, stride `0x40000` |
| virtual timer | GIC INTID 27 (DT PPI 11; no `virtual-timer-intid` in the tree) |
| UFS host | `0x1d84000+0x3000`, `ro.boot.bootdevice` = `1d84000.ufshc` |
| touch | Goodix on QUPv3 SPI, `xiaomi,m11a-spi`, SE4 `0x990000`, IRQ TLMM GPIO21, reset GPIO20, AVDD GPIO71; its pin registers are at `0x0f100000`, not the `0x0f000000` the DT node declares: that 16 MB region starts with a 1 MB hole, and a read there wedges the interconnect until the watchdog resets the phone |
| volume up key | PM8350 GPIO6 (`&pm8350_gpios 6`) |
| SPMI arbiter | version 7 (`0x70000000`) |

Partition geometry (from `fastboot getvar`): `boot` 192 MiB, `vendor_boot`
96 MiB, `recovery` 100 MiB, `misc` 4 MiB (holds the A/B BCB), `vbmeta`
0x20000, `dtbo` 0x1800000, `userdata` on LUN 0 starting at block `0x2f8a00`;
the temporary Android split used for the 2026-10-28 capture is gone, `userdata`
is a single partition and no dual boot is planned. This device has **no `init_boot`**.

## Traps already paid for

**`kill` takes a PID; a name restarts nothing.** `kill SpringBoard` is `kill 0`
(`kill 0 -> 3`), so the dylib in `/private/var/vm` is never mapped and a rebuilt
probe reads as "did not run" while the old hook keeps answering.
`tools/usb-ring.py respring` kills the PID from the kernel's own `SMP` line.

**The window of RAM.** `phys_base = 0x840000000`, `mem_size = 0x240000000`
(the clean 9 GiB run: the tree's 3 GiB and 6 GiB regions are adjacent, with no
reservation inside). Rules that still cost resets:

- it must start above firmware memory and above the shim **including the
  appended LZ4 payload**, because the loader wipes the window before it
  unpacks. `_end` is a runtime address, not an offset (symbols are
  PC-relative), and the `LZ4P` magic is `0x50345a4c` little-endian;
- the base must be 32 MiB aligned, and `boards.py`/`shim/board.h` must be the
  window the shim passes: `mkadt.py` writes the pair into `/chosen` as
  `dram-base`/`dram-size`, and the shim puts it in `boot_args`;
- it must end in memory that exists (XNU takes its first heap pages from the
  *end*) and not **contain** a carve-out or hole: the VM hands out pages
  across the window, and a page on a firmware island aborts (`Kernel data
  abort`, `far` inside the physmap).

The splash framebuffer (`0xb8000000`) is outside the 9 GiB window; `start.S` no
longer maps it `VA=PA` (`0295` installs a VA alias), and the **physmap slide**
comes from `/chosen/random-seed`, so a random seed makes the boot a coin flip
(about one host boot in three dies); `boards.py` pins the seed, `ADT_SEED`
overrides it.

**The kernel's command line is the payload's, not ABL's.** With `fastboot
boot`, ABL fills `/chosen/bootargs` with an Android line (~1 KiB) and
`BOOT_LINE_LENGTH` is 1024: a shim that copies it first loses `rd=ufsroot0` and
the rest of the payload, and the kernel waits for a root that never appears.
The shim reserves the payload's room first and gives ABL's line what is left;
`fastboot boot --cmdline "..."` still overrides.

**Page size: 16 KiB, and the three pieces must agree.** `ID_AA64MMFR0_EL1`
reports `TGran16=1` (measured 2026-10-23; the shim prints it as `tg16`), so
mondrian runs the granule iOS is built for. These are the failures that cost
time:

| symptom | cause | where |
| --- | --- | --- |
| `disallowing unsupported code signature page shift: 14`, then launchd cannot load `libSystem` | the dyld cache's code directory is 16 KiB; a 4 KiB kernel refuses it (and would panic on a non-16 KiB-aligned hash offset) | `0001` (`__ARM_16K_PG__`), `tools/boards.py` |
| `LOADER ramdisk overlaps kernel memory` | `virt_base` must sit one L2 block (32 MiB) below the text, so the kernel image reaches past a fixed 32 MiB scratch offset and the ramdisk copy overwrites the payload it reads from | `shim/loader.c` (unpack at the top of the window) |
| no console at all after the shim | the granule is `BOARD_PG_SHIFT`: TCR TG0/TG1, 2048-entry tables, 32 MiB blocks | `shim/board.h`, `shim/mmu.c` |

**QHEE owns the physical timer.** Writing `CNTP_CTL_EL0` from EL1 is an
*undefined instruction* (EC 0, not 0x18), so `0061` drops the write; the virtual
timer fires once the guest unmasks it for EL1 (`0069`), and `0173` programs
`CNTV_TVAL` before clearing IMASK or the level-sensitive PPI storms.
`-march=armv8.5-a+crypto` also emits 226 RCpc `ldapr`s these cores lack (no PAC
either), unlike QEMU's `-cpu max`: keep plain `arm64`.

**`ml_io_map()` traps twice: it never unmaps, and an early mapping dies.** The
I/O submap is 8 MiB, so re-mapping a 128 KiB touch DB per lookup, 4 MiB of SPMI
channels for one byte, or a driver's windows on every command (BT mapped 480 KB
per `btuart`) exhausts it: the first command after boot works, the next aborts.
A request larger than the free hole blocks in `kmem_alloc(KMA_NOFAIL)` instead
(Venus's 1 MiB SMMU map hung its worker: use `ml_io_map_unmappable`). The same
window limit makes `flush_dcache64(pa, ..., TRUE)` spin on a low-bank PA; pass the VA.
Map each window once and keep it (`0179`), and remember it belongs to one APID --
the next peripheral re-maps or the byte lands in the previous page. A mapping
taken before `STARTUP_SUB_KMEM` comes from `virtual_space_start`: once the VM
owns that space the next read is a bus abort (`fault_code=0x10`), which is why
`0087` re-maps GICD/GICR after the VM is up and `0062` keeps the early framebuffer alias.

**`delay()` takes microseconds.** Venus's "after 1 s" `CTRL_STATUS` poll was
`delay(1)` (1 ms total); at 1 ms per try the same firmware answers `0x40000001`.

**The HFS journal cannot be replayed, and a dirty volume hides as a dead kernel.**
The `HFS_ENABLE_JOURNALING` sysctl creates one, and then every mount hangs *before*
the framebuffer: no ring, no userland left to undo it. `mondriannojnl=1` mounts
ignoring it; the disable sysctl panics (`journal_close(NULL)` has no NULL check),
and a copy of `backup/ios-root.simg` expanded and repaired with `fsck.hfsplus` mounts a volume that will not.

**A record whose size outruns its blocks is what marks the volume.** `ExtendFileC`
reserves blocks without touching the disk (`kEFDeferMask`) and grows the size with
them; giving the reservation back for a real allocation that then fails leaves the
size without the blocks, and the record goes to disk because
`hfs_prepare_fork_for_update` only checked invalid ranges (`0365` trims it). Every
lookup then fails `EINVAL`; `0364` presents only the bytes the blocks can back.

**The ABL does not hand the ramdisk over.** It gunzips it, and the bytes at
`/chosen/linux,initrd-start` are not the payload: that travels **appended to the
shim image** as an LZ4 blob (`shim/out/payload.lz4p`, unpacked by `shim/lz4.c`).
Never write the blob over `shim/out/payload.bin`, the raw payload (a header
promising 0 bytes, so `LOADER cannot unpack the payload`); the checker is
`tools/check-shim-blob.py IMAGE`.

**The shim is not a no-op, and it can hide kernel bugs.** The full shim runs
`test_gic()` before the jump: it arms `CNTV_TVAL`, storms until it gives up and
leaves the UFS warm. With `SMALL_SHIM=1` the kernel arms the timer itself
(`0173`) and wakes the UFS, and `test_ufs()` faults on a fastboot boot, so that
build also needs `SHIM_NO_UFS`. IRQ lines and no `MONDRIAN EARLY` means the
shim, not the kernel.

**fastboot serves 768 MiB per download and cannot split a raw image.** A bigger
raw file is resparsed and fails to read back; flash sparse (`tools/mk-simg.py`).

**Kernel timeouts stop after userland starts.** Threads paced by
`tsleep(timeout)` wake once and never again; pace from work (`0100`) or `delay()`.

**The console paints the kernel log and scrolls.** `0210` clears the panel once
and scrolls half a screen at the last text row, `0213` paints from the log thread,
and `0005`'s fbcon puts text over the ABL logo. `0351` gives the panel to the
compositor at its first swap and `0352` sends a survived kernel abort to the ring;
`mondrianfb_noconsole=1` takes the screen at probe, `=0` is the only log with USB dead.

**dyld ignores `DYLD_INSERT_LIBRARIES` unless the MAC policy named exactly
`AMFI` answers `__mac_syscall` 0x5a.** Any other name returns `ENOPOLICY`;
dyld then drops the variable silently (no error, no crash, the process stays
healthy) and the library never loads. `0108` registers `AMFI` and allows
everything for 0x5a and 0x60.

## UFS bring-up, the sequence that works

UFS 3.1 host at `0x1d84000`; the sweet driver's register names still exist but
the UTRD is 16 dwords and the PRDT entries are 64-bit. The sequence that wakes
it — GCC branch, transfer-list takeover, `hce 0x1 hcs 0x10f`, START STOP UNIT
active on the well-known LUN `0xd0`, then TUR on LUN 0 — is in the
`mondrian-ufs-debug` skill. The ABL leaves the UFS powered on a normal boot and
powers it down in fastboot; the kernel brings the host up itself either way
(`0074`-`0076`). Wait loops are spin counts, not `delay()`: a wait that never
completes has to be non-fatal and dump `hcs/is/dbr` plus the UTRD. The write
path is `0090` (WRITE(10), read-modify-write, SYNCHRONIZE CACHE).
`0516` bounds the GPT entry table with `nent > BOUNCE_SIZE / esz`: the earlier
`nent * esz > BOUNCE_SIZE` was a 32-bit product that a corrupt header could wrap,
passing the check and asking `ufs_read_blocks()` for a bogus count.

## Display

The panel is **command mode** (`dsi_cmd_mode`, boot arg
`msm_drm.dsi_display0=qcom,mdss_dsi_m11a_42_02_0a_dsc_cmd`, 1440x3200, DSC;
the property list is in `docs/MONDIAN_REFERENCE.md`), so it needs one
`CTL_START` per frame: a store into the framebuffer memory never reaches it,
and the ABL's scan is not a driver. The ABL leaves a 43 MiB splash carve-out at
`0xb8000000` (`0x2b00000`) that the DPU scans; the kernel writes the same memory
through the early WC alias. The boot arguments call it RAM: keep the frames off
the free list (`mondrian_page_is_screen()`) or `vm_page_init`'s assert fires
(`0083`); `0085` presents IOSurface swaps through `AppleCLCD` on
`/arm-io/disp0`.

**A frozen interface is the bootloader's autorefresh.** It leaves
`INTF_TEAR_AUTOREFRESH_CONFIG = 0x8000003c` (60 frames) and
`INTF_TEAR_CHECK_EN = 1`; clear both **before the first `CTL_START`**, or the
interface stops after 60 frames and only `CTL_SW_RESET` (`0x030` = 1) brings it
back. `CTL_START` (`0x01c`) bit 0 clears on completion and stays 1 if it never did.

**A short DCS write is four bytes,** `(type << 16) | data0 | data1 << 8`; the
`0xc0` long form is dropped by the panel and the 120 Hz switch stays at 60 (`0408`).

**The kick is the default.** `MondrianFramebuffer` writes the frame, `dsb sy`,
`CTL_FLUSH` (`0xc00607ff`) then `CTL_START`, Normal Non-cacheable: CTL0 is the
active controller, INTF1 the interface, and both timing-engine enables are 0.

**Direct scanout is slower and strands the bootloader.** `mfs=4` (`0410`) holds
the surface on the glass for a period (68-71 fps against 81-87 with the copy);
even `mfs=2` leaves ABL with **no USB at all** on a warm reset, and restoring the
bank's registers does not fix it. The copy path is the default.

**Brightness: one DMA path, one low page.** DCS `0x51` only reaches the panel
through the embedded DMA (a FIFO send wedges the engine: `INT_CTRL` `0x500`,
no `DMA_DONE`; reset the FIFO first), and `DSI_CTRL.CMD_MODE_EN` stops it
reporting completion. `DSI_DMA_CMD_OFFSET` is 32 bits while the window starts at
`0x840000000`: the splash's last page, `0xbaaf0000` (`shim/board.h`), is the only
low page this port owns. `mondrianbl=<DBV>`
(0xfff full scale), `bl LEVEL [FMT [CMD]]` and `IOMobileFramebuffer` selector 100
(`0314`) set the level, `mondrianblfmt` the byte order; `brightness-nits` 0 is
"display asleep".

**The battery's VADC read: sleep, never poll.** ADC7 has no polling mode, so a
reader that polls the arbiter's EOC word takes the *previous* conversion (0.8 V
to 11 V in one series), and `DATA0` is the low byte. `0304` waits, checks EOC
and fault, publishes only a pair that agrees (`sav` prints one), and stays off
the frame path: in `vsyncFired` that wait was `1 frame in ~5000 ms`.

## Keys over SPMI

The shim no longer shows a boot menu: `shim.c` boots the payload directly and
the key probe still runs, because the status bytes are worth a photo of a failed boot.

The arbiter is version 7: observer channel stride `0x20`, APID
map at `core+0x2000+4n`, owner table at `cnfg+4n`. `KPDPWR` is bit 7 (power),
`RESIN` bit 6 (volume down — hence no `vol_down` node); volume up is PM8350
GPIO6 on peripheral page `0x8d`, level bit 0, held LOW. A PMIC gpio is its own
page (`0x88 + index - 1`), and the PON node has no `__symbols__` label: find it
by the `pon` compatible. A refusal prints
`spmi code N` with N naming the failing step in `shim/spmi.c`: one photo names
it. A failed transaction is a busy arbiter, not a broken bus -- the battery's
conversion runs on it every 2 s -- and treating one collision as fatal ended
button polling for the rest of the boot; `keys` prints the poller's state and
one live read of both registers.

**The APID table cannot be written from the AP.** It only holds what XBL gave
EE0 (540 of 1024 here, `si APID` over the USB channel); the charger has no entry
at all (`ppid 0x310`, PM8350B's SMB5) because `pmic_glink` on the ADSP reaches
it. An `smw` write wedges the arbiter: the SPMI thread never returns and the ADC
tick dies with it, while ping still answers.

Other ports worth reading, with what each solves and its licence: `docs/REFERENCE_PORTS.md`.
