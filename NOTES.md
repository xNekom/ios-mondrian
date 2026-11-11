# ios-mondrian — engineering notes

Port of [ios-sweet](https://github.com/dipa-studio/ios-sweet) to the **POCO F5
Pro / Redmi K60** (`mondrian`, Qualcomm SM8475 / Snapdragon 8+ Gen 1): Apple's
open-source XNU (xnu-8796, the iOS 16 generation) running the unmodified
iPhone X iOS 16.7.16 userland.

This file holds the state of the port and the facts that were expensive to
learn; the work list, the hardware delta and the partition rules are in
`docs/MONDIAN_PORT.md`. The upstream `sweet` port is the reference
implementation and is not re-described here: `xnu/patches/` is its record.

## State (2026-11-10)

- **Boot chain.** ABL → `fastboot boot` (or the `boot_b` image) → shim → XNU.
  The shim reads the live device tree, unpacks the LZ4 payload and jumps. The
  console draws into the splash framebuffer the ABL leaves at **0xB8000000**
  (1440x3200, stride 5760). Build with `SMALL_SHIM=1` (`tools/phone-deploy.sh`
  does); why is in the shim trap.
- **Fastboot, and the only way back to it.** `fastboot devices` answers in the
  bootloader's fastboot (power + volume down), which takes `fastboot boot`;
  fastbootd refuses it, `fastboot reboot bootloader` keeps USB alive. ABL
  spends one retry per boot, so after seven the slot reads
  `slot-unbootable:b:yes` and refuses every image; `fastboot set_active b`
  resets flag and budget without writing a partition.
  **Never reset the phone from iOS.** Measured twice: it lands in the
  bootloader's charging screen with the phone off, which costs a manual
  recovery and blocks every test until the battery is back; the BCB's
  `bootloader`/`boot-fastboot` and IMEM 0x65c all boot the active slot.
- **Kernel.** Reaches `bsd_init` through `arm_init`, VM init, IOKit, the
  scheduler and AMFI; the GIC and vtimer fixes (`0116`, `0173`) are in the traps.
- **UFS, end to end.** Host clocked, NOP/QUERY answered, the LU woken through
  the device well-known LUN, the GPT parsed, `userdata` located, HFS+ root
  mounted and `launchd` exec'd. The console ring is armed at the end of the
  UFS probe, before `vfs_mountroot` (`0174`), so a failed mount leaves its
  error on disk.
- **USB, both directions.** `usb=1` probes the DWC3 the ABL leaves powered;
  `usb=2` runs the gadget: an ECM device at 192.168.7.2, control on udp/5141.
  `tools/usb-ring.py` dumps the ring, photographs the panel (`screen`), injects
  `tap`/`swipe`/`key`, measures the glass's frame rate (`fps`) and prints `mem`;
  `tools/ios-usbnet.sh` sets the host up and streams udp/5140.
- **iOS userland.** `0089` handles root-auth ENOTTY; launchd reaches 150
  processes and `0112` injects the UI dylib per daemon (`mondrian_ui_hook`).
  `0090` adds WRITE(10) and the write path; `DKIOCISWRITABLE` must agree or HFS
  disables writes.
- **Display and UI.** The home screen draws on its own 1440x3200 canvas
  (480x1066 pt at scale 3) and the tick holds two records (`0282`). Measured at
  the glass on 2026-11-11 (`usb-ring.py fps`): 0.2 panel changes a second while
  a CoreAnimation animation and a swipe run, with every display link at 60 Hz,
  so `present 0/s` is the compositor fault in `docs/UI_PERFORMANCE.md`, not an
  idle screen. CoreAnimation needs `TimingElements`/`ColorElements` and an
  `IOAcceleratorES` service (`0114`); Mesa 25.0.7 draws through freedreno.

Current blockers, in order:

1. **The battery.** Nothing drives the charger: it has no APID in the AP's SPMI
   table (trap below), so a boot runs the phone down. The level comes from the
   PMK8350 VADC (`mondrian_spmi_adc_mv()`, `sa SID CHAN DIV` over USB).
2. **The compositor stops drawing.** Some boots never put a frame on the
   glass: `backboardd` commits 3-7 frames at 5 ms each, then goes silent and the
   screen keeps the boot logo. That is the GPU write-target bug in
   `docs/MONDIAN_GPU.md`, not the panel (the tick still runs at 60 Hz). A dirty
   root volume gives the same symptom with no USB at all; see the journal trap.
3. **Control Center.** `mondrianwin=1` aborted SpringBoard; without it the
   sheet draws full size. The slider ignores taps and the bottom banding stays.
4. **The rest.** The GPU's glitches (`docs/MONDIAN_GPU.md`), audio, modem, cameras.

## Building and booting

**Kernel.** `.github/workflows/xnu.yml` and both local builds
(`tools/build-kernel-local.sh` on the Mac, `tools/wsl/build-kernel.sh` on
Windows/WSL2, `docs/BUILD_LINUX.md`) fetch xnu-8796.141.3, reset the checkout
and apply `xnu/patches-mondrian/`; a skipped patch fails the run (the
workflow's "No skipped patches" step greps the log). Run `tools/apply-series.py`
(or `tools/check-patches.sh`) after touching the series: it names the patch in
seconds (`0161` was silently missing until 2026-10-28, `0157` carried its first
hunk). **The series is the only source of truth:** a build whose hash changed
resets that checkout, so a driver edited there and never exported to a patch is
lost — measured 2026-11-11: the DSI brightness driver and the ring's
`bl`/`dcs`/`blob` commands went that way (`docs/BUILD_LINUX.md`). A mondrian
build also needs the local `mondrian_gmu_fw.h`; `0184` stubs the user-client
surface without the CP profile.

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
ring that `0174` arms before `vfs_mountroot`, so a failed mount still leaves the
log on disk. `mondrianfb_noconsole=1` stops painting the panel at the first
CoreAnimation swap, so a photo can show an earlier boot: the ring is the truth.
With the kernel running, `usb=2` and `tools/usb-ring.py dump` read the whole
ring over USB. On Windows the phone reaches WSL through `usbipd attach --wsl
--busid <id>` and `cdc_ether`: the host driver was the missing half, and a
detach/attach is a bus reset the gadget now survives (`0298`).
A previous boot is read by running the real kernel, then a dump kernel
(`mondriandump=1`, `mondriandumpmatch=`, `0099` splits the list).
`mondrianstop=N` halts at early mark N with IRQs masked, and `0174` keeps marks
above 20 visible after the console is off, so the last line on the panel names
the function that hung.

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
the temporary Android split and its exact restore are in `docs/DUAL_BOOT.md`.
This device has **no `init_boot`**.

## Traps already paid for

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

The splash framebuffer (`0xb8000000`) is outside the 9 GiB window; `start.S`
no longer maps it `VA=PA` and `arm_vm_init` installs the explicit kernel VA
alias for the early console (`0295`).

The **physmap slide** comes from `/chosen/random-seed`, so a random seed
makes the boot a coin flip (about one host boot in three dies); `boards.py`
pins the seed and `ADT_SEED` overrides it.

**The kernel's command line is the payload's, not ABL's.** With `fastboot
boot`, ABL fills `/chosen/bootargs` with its own Android line (~1 KiB), and
`BOOT_LINE_LENGTH` is 1024: a shim that copies it first loses `rd=ufsroot0`
and the rest of the payload (the same silent cut that hid
`mondrianiconset=1` past 608 in ring225), so the kernel reaches BSD init and
waits for a root that never appears. The shim now reserves the payload's room
first and gives ABL's line what is left; `fastboot boot --cmdline "..."` still
overrides.

**Page size: 16 KiB, and the three pieces must agree.** `ID_AA64MMFR0_EL1`
reports `TGran16=1` (measured 2026-10-23; the menu prints it as `tg16`), so
mondrian runs the granule iOS is built for. These are the failures that cost
time:

| symptom | cause | where |
| --- | --- | --- |
| `disallowing unsupported code signature page shift: 14`, then launchd cannot load `libSystem` | the dyld cache's code directory is 16 KiB; a 4 KiB kernel refuses it (and would panic on a non-16 KiB-aligned hash offset) | `0001` (`__ARM_16K_PG__`), `tools/boards.py` |
| `LOADER ramdisk overlaps kernel memory` | `virt_base` must sit one L2 block (32 MiB) below the text, so the kernel image reaches past a fixed 32 MiB scratch offset and the ramdisk copy overwrites the payload it reads from | `shim/loader.c` (unpack at the top of the window) |
| no console at all after the shim | the granule is `BOARD_PG_SHIFT`: TCR TG0/TG1, 2048-entry tables, 32 MiB blocks | `shim/board.h`, `shim/mmu.c` |

The 4 KiB era left `0056`/`0057`/`0062` (commpage, zone map VA, 32 MiB low globals); they still apply.

**Instructions the platform does not have.** With `-march=armv8.5-a+crypto` the
kernel emitted 226 RCpc `ldapr`s; these cores have neither RCpc nor pointer
authentication, so the phone faults where QEMU's `-cpu max` does not.

**QHEE owns the physical timer.** Writing `CNTP_CTL_EL0` from EL1 is an
*undefined instruction* (EC 0, not the EC 0x18 a trapped sysreg gives), so
`0061` drops the write; the virtual timer fires once the guest unmasks it for
EL1 (`0069`), and `0173` programs `CNTV_TVAL` before clearing IMASK or the
level-sensitive PPI storms. With no RTC service, `IOKitInitializeTime()`'s 30 s
`IORTC` wait is skipped on this board.

**Anything mapped with `ml_io_map()` before `STARTUP_SUB_KMEM` dies.** It is a
bootstrap mapping taken from `virtual_space_start`; once the VM owns that
address space the device is mapped nowhere and the next read is a bus abort
(`fault_code=0x10`, `FSC_SYNC_EXT_ABORT`). `0087` re-maps GICD/GICR through
`ml_io_map()` after the VM is up; the early framebuffer survives only because
`0062` keeps a reserved low-global alias for it.

**`ml_io_map()` never unmaps; the I/O submap is 8 MiB.** Re-mapping a 128 KiB
touch command DB per lookup and 4 MiB of SPMI channels for one byte both
exhausted it, and the next `kmem_alloc` panicked in `io_map`: map the one 4 KiB
window (`0179`), and remember it belongs to one APID - the next peripheral has
to re-map or the byte lands in the previous page.

**The HFS journal cannot be replayed, and a dirty volume looks like a dead
kernel.** The `HFS_ENABLE_JOURNALING` sysctl does create a journal, and from
then on every mount hangs *before* the framebuffer: the screen keeps the shim
log (`STAGE`, `XNU jumping`) and the USB gadget never appears, so there is no
ring and no userland left to undo it. `mondriannojnl=1` mounts ignoring the
journal; the disable sysctl is not the way out, because `journal_close(NULL)`
has no NULL check and panics. A volume left dirty by a mid-boot panic shows the
same signature; reflashing `backup/ios-root.simg` is the repair.

**`hfs_mark_inconsistent` on this volume is usually our own check.** A catalog
entry that claims data and owns no blocks is rejected on every open (2 560
times in one boot); a pristine image has none, so the hard resets write that
damage. `hfs_zero_block_stub()` exempts the legal under-one-block case.

**The ABL does not hand the ramdisk over.** It gunzips it, and the bytes at
`/chosen/linux,initrd-start` are not the payload. The payload travels
**appended to the shim image** as an LZ4 blob (`shim/out/payload.lz4p`, unpacked
by `shim/lz4.c`). Never write the blob over `shim/out/payload.bin`, the raw
payload: that truncates it to a header promising 0 bytes and the shim answers
`LOADER cannot unpack the payload`. `tools/check-shim-blob.py IMAGE` reads the
header back.

**The shim is not a no-op, and it can hide kernel bugs.** The full shim runs
`test_gic()` before the jump: it arms `CNTV_TVAL`, storms until it gives up and
leaves the UFS warm. With `SMALL_SHIM=1` the kernel arms the timer itself
(`0173`) and wakes the UFS, and `test_ufs()` faults on a boot from fastboot
(host powered down), so that build also needs `SHIM_NO_UFS`. Panel showing IRQ
lines and no `MONDRIAN EARLY` means the shim, not the kernel.

**fastboot serves 768 MiB per download and cannot split a raw image.** A bigger
raw file is resparsed and reading it back fails; flash a sparse image instead
(`tools/mk-simg.py`), which fastboot sends in `-S` chunks.

**Kernel timeouts stop after userland starts.** Threads paced by
`tsleep(timeout)` wake once and never again; pace from work that runs (`0100`)
or `delay()`.

**The console paints the kernel log and scrolls.** `0210` clears the panel once
and scrolls half a screen at the last text row; `0213` moves the painting into
the log thread. `0005` registers the fbcon unconditionally, so text lands on
the ABL logo from the first `printf`; `mondrianfb_noconsole=1` keeps the panel
for the UI, and `mondrianfb_noconsole=0` is the only log there is when USB is
dead.

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
(`0074`-`0076`).

Wait loops are spin counts, not `delay()`: a wait that never completes has to be
non-fatal and dump `hcs/is/dbr` plus the UTRD.

The write path is `0090` (WRITE(10), read-modify-write, SYNCHRONIZE CACHE).
**Known debt:** `ufs_find_partition()` bounds the entry table with
`nent * esz > BOUNCE_SIZE`, a 32-bit product a corrupt table can wrap; guard
with `nent > BOUNCE_SIZE / esz`.

**HFS+ corruption shows as `hfs_mark_inconsistent`.** `fsck.hfsplus -fy` on a
copy of the 16 GiB root names the damage (overlapped extents, a bad volume
bitmap, a wrong free-block count); repeat until it says `appears to be OK`,
then push the changed blocks back. Once it complains about the allocation-block
count or the extents node (block 2178, `0x882000`) is zeroed, rebuild the root
from `backup/ios-root.simg`; the live GPT has a single `userdata`.

## Display

The panel is **command mode** (`dsi_cmd_mode`, boot arg
`msm_drm.dsi_display0=qcom,mdss_dsi_m11a_42_02_0a_dsc_cmd`, 1440x3200, DSC;
the property list is in `docs/MONDIAN_REFERENCE.md`), so it needs one
`CTL_START` per frame: a store into the framebuffer memory never reaches it,
and the ABL's scan is not a driver. The ABL leaves a 43 MiB splash carve-out at
`0xb8000000` (`0x2b00000`) that the DPU scans; the kernel writes the same memory
through the early WC alias. The boot arguments call it RAM: keep the frames off
the free list (`mondrian_page_is_screen()`) or `vm_page_init`'s assert fires.
`0083` does that; `0085` presents IOSurface swaps through `AppleCLCD` on
`/arm-io/disp0`.

**A frozen interface is the bootloader's autorefresh.** It leaves
`INTF_TEAR_AUTOREFRESH_CONFIG = 0x8000003c` (autorefresh, 60 frames) and
`INTF_TEAR_CHECK_EN = 1`; clear both **before the first `CTL_START` of the
session** and the interface runs indefinitely (measured 9,813 frames at
59-61/s). Clearing them later does not recover it; `CTL_SW_RESET` (`0x030` = 1)
does. `CTL_START` (`0x01c`) bit 0 self-clears on completion and stays 1 when it
never completed.

**The kick is the default.** `MondrianFramebuffer` writes the frame, `dsb sy`,
`CTL_FLUSH` (pending `0xc00607ff`) then `CTL_START`; the stores are Normal
Non-cacheable. CTL0 is the active controller, INTF1 the interface; in command
mode `INTF_TIMING_ENGINE_EN` and `INTF_DSI_CMD_MODE_TRIGGER_EN` are 0.
`mondrianfb_mdp`, `mondrianfb_kick=N`, `mondrianfb_test` and
`mondrianfb_defer=0` are diagnostics; see `docs/MONDIAN_GPU.md`.

**Brightness: one DMA path, one low page.** DCS `0x51` reaches an AMOLED panel
only through `dsi_ctrl_hw_cmn_kickoff_command`'s embedded DMA: the command FIFO
acks and changes nothing, and worse, a FIFO send wedges the DMA engine for the
rest of the boot (`INT_CTRL` `0x500`, no `DMA_DONE`, `STATUS` 0) -- reset the
command FIFO before the next send. Do not write `DSI_CTRL`: `CMD_MODE_EN` on
this video-mode controller is what stopped the engine reporting completion.
`DSI_DMA_CMD_OFFSET` is 32 bits and the kernel window starts at `0x840000000`,
so no allocator can serve it (IOKit's physical mask is ignored: pages at
`0x846924000`); the last page of the splash carve-out, `0xbaaf0000`
(`shim/board.h`), is the only low page this port owns. `mondrianbl=<DBV>` sets
the boot level (0xfff full scale) and `brightness-nits` 0 means "display
asleep": honouring it left every boot at DBV `0x20` with a dead slider.

## Boot menu and dual boot

`shim/menu.c` + `shim/menu_logos.h` (rasterized by `tools/gen-menu-logos.py`),
preview in `docs/menu-preview.png`. Full-screen page, one card per choice,
selection as a ring; a selection change repaints only the two card borders.

**Keys (SPMI).** The arbiter is version 7: observer channel stride `0x20`, APID
map at `core+0x2000+4n`, owner table at `cnfg+4n`. `KPDPWR` is bit 7 (power),
`RESIN` bit 6 (volume down — hence no `vol_down` node); volume up is PM8350
GPIO6 on peripheral page `0x8d`, level bit 0, held LOW. A PMIC gpio is its own
page (`0x88 + index - 1`), and the PON node has no `__symbols__` label: find it
by the `pon` compatible. Rising edges drive the menu. A refusal prints
`spmi code N` (1 arbiter, 2 reg-names, 3 regions, 4 missing, 5 count, 6 pon,
7 ppid, 8 apid, 9 gpios, 10 gpio ppid, 11 gpio apid, 12 vol_up), so one photo
names the defect.

**The APID table cannot be written from the AP.** It only holds what XBL gave
EE0 (540 of 1024 here, `si APID` over the USB channel); the charger has no
entry at all (`ppid 0x310`, PM8350B's SMB5) because `pmic_glink` on the ADSP
reaches those. An `smw` write wedges the arbiter: the SPMI command thread never
returns and the ADC tick dies with it, while ping still answers. Buttons.

## Other ports worth reading

- **`UniXNU/UniXNU`** — bootstrap capacity (`0001`) and the UFS LU wake.
- **Bergamota / Chlorophyll / HackiOS** — CPU fallback, persona hook `0106`;
  **`oosexgang/hakios-xnu-kernel`** — `eagl.c`, one revision ahead.
- **`palazik/ios-dodge`**, **`MakrSas/ios-topaz`**, **`Log1nYT/ios-sweet`** —
  TLB flush, timer quiesce, `cpus=1`, DWC3 clocks.
