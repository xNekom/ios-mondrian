# ios-mondrian — engineering notes

Port of [ios-sweet](https://github.com/dipa-studio/ios-sweet) to the **POCO F5
Pro / Redmi K60** (`mondrian`, Qualcomm SM8475 / Snapdragon 8+ Gen 1): Apple's
open-source XNU (xnu-8796, the iOS 16 generation) running the unmodified
iPhone X iOS 16.7.16 userland.

This file holds the state of the port and the facts that were expensive to
learn; the work list, the hardware delta and the partition rules are in
`docs/MONDIAN_PORT.md`. The upstream `sweet` port is the reference
implementation and is not re-described here: `xnu/patches/` is its record.

## State (2026-10-26)

- **Boot chain.** ABL → `fastboot boot` (or the `boot_b` image) → shim → XNU.
  The shim reads the live device tree, unpacks the LZ4 payload and jumps. The
  kernel console draws into the splash framebuffer the ABL leaves at
  **0xB8000000** (1440x3200, stride 5760).
- **16 KiB pages.** The SoC reports `TGran16=1` in `ID_AA64MMFR0_EL1`, so
  shim, payload and kernel all run the granule iOS is built for:
  `__ARM_16K_PG__`, `ARM_PGSHIFT` 14, 32 MiB L2 blocks, the Apple VA layout.
- **Kernel.** Gets through `arm_init`, VM init, `kmem_range_init`, IOKit, the
  scheduler and AMFI into `bsd_init`. The GIC is remapped after the VM takes
  over; the vtimer PPI (27) delivers once its active state is ended and its
  Group 1 secure modifier cleared (`0116`), and every timed wait returns.
- **UFS, end to end.** Host clocked, NOP/QUERY answered, the LU woken through
  the device well-known LUN, the GPT parsed, `userdata` located, and the block
  device reaches HFS.
- **iOS userland.** `0089` handles root-auth ENOTTY; launchd reaches 150
  processes. `0112` injects the UI dylib per daemon (`mondrian_ui_hook`: 1
  containermanagerd, 2 backboardd, 4 SpringBoard); `hook=7` loads all three.
- **Writable root.** `0090` adds WRITE(10), SYNCHRONIZE CACHE and the write
  path; `DKIOCISWRITABLE` must agree or HFS disables writes.
- **Display and UI.** The lock screen is up. CoreAnimation needs
  `TimingElements`/`ColorElements` and an `IOAcceleratorES` service (else it
  waits 30 s and draws nothing); `0114` publishes them and leaves the software
  renderer. The panel is written through the console alias, never through an
  `IOMemoryDescriptor` or `PE_initialize_console(kPEDisableScreen)`: both put a
  device pager on managed pages and panic in `pmap_remove_pv`. SpringBoard then
  waits on MobileActivation in `_setupActivationState`; the dylib forces
  activation and skips Setup. A freshly flashed root takes the setup path (no
  `mobileactivationd` container, `budd` runs), so the dylib also forces
  `SBLockdownManager` `init`/`sharedInstance` and answers `SBSetupManager`'s
  real gates (`-isInSetupMode`, `_isInSetupMode`,
  `isInSetupModeForDeviceMigration` NO; `isInSetupModeReadyToExit`,
  `setupHasFinishedRestoringFromBackup` YES). There is no `-isSetupRequired`.
  The mondrian cmdline in `tools/boards.py` carries `mondrian_ui_hook=7`; the
  root must have `/usr/libexec/mondrian-ui-hook.dylib`, and a boot without the
  hook sits at the Apple logo.
- **Swap path.** The macOS SDK defines `XNU_TARGET_OS_OSX`, so the pager looked
  for `/System/Volumes/VM/swapfile`; `0098` uses `/private/var/vm/swapfile`.

Current blockers, in order:

1. **UI performance.** The touch works (`0153`), but its 220 KB firmware loads
   over the bit-bang SPI at every boot. `ml_get_timebase()` reads 609 MHz
   here, not the 19.2 MHz timer: 800 ns became 26 us and the load 160 s.
   `0156` uses nanoseconds_to_absolutetime, so it is 8 s and the touch is
   ready before the first frame (41 s vs 49 s). Keep the bring-up before
   `launchd`: a thread raced the RPMh iovdd vote and wedged userland. The CPU
   renderer draws at 8-30 fps (43 peak); the GPU is next (MONDIAN_GPU.md).
2. **Buttons.** Power/volume-down on PMK8350 PON, volume-up on PM8350 GPIO6 not read yet.
3. **Rest.** Audio, USB, modem and cameras: the daemons that abort
   (SiriTTSSynthesizer, KonaSynthesizer) want them.

## Building and booting

**Kernel.** `.github/workflows/xnu.yml` fetches xnu-8796.141.3, applies
`xnu/patches-mondrian/` in order and uploads `kernel.development.mondrian`.
`tools/build-kernel-local.sh` runs the same build on this Mac (pinned
`blacktop/darwin-xnu-build` tree, same series, cached KDK 13.5) and fails if a
numbered patch is skipped. `tools/apply-series.py` applies the series to a
fresh tree in seconds and names what does not apply, and
`tools/check-patches.sh` does the same against the cached tree in `research/`.

**`iig` trap.** The build reuses the generated DriverKit stubs
(`*.iig.cpp`/`*.h` under `build/xnu.obj/DEVELOPMENT_ARM64_MONDRIAN/iokit/`,
note the extra `DEVELOPMENT` component). Regenerating them with a newer
Xcode's `iig` fails with `no member named 'kernelContent' in 'IORPC'`, so
`build/kernel` must stay seeded from an Xcode 15 tree.

**Image and deploy.** `tools/phone-boot.sh` builds if needed and boots
volatile. `tools/phone-deploy.sh` (push/install/backup/reboot) is the adb path
for writes to the boot partition, and refuses `boot_a` unless `BOOT_A=1`.

**Reading a boot.** `0096` tees kernel and `/dev/console` output into a 4 MiB
ring; `0097` starts persistence after root mount, flushes immediately, and
verifies the header. Inspect a previous boot by running the real kernel, then a
dump kernel with `mondriandump=1` and
`mondriandumpmatch=SMP,CRASH,swap,memorystatus` (`0099` splits the list). The
dump reads the prior ring before starting its own writer; the shim `logview` is
unreliable on this UFS host.

**Host-side testing.** `tools/qemu-ios.py` boots the payload; `--kernel` only
feeds its decoder (`docs/QEMU_TESTING.md`), so rebuild the payload.

## Measured hardware facts

From the live device tree (and from the shim's own dump):

| what | value |
| --- | --- |
| `/memory` | `0x80000000+0x6a000000`, `0xf4600000+0xba00000`, four regions above 32 GB |
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
0x20000, `dtbo` 0x1800000, `userdata` on LUN 0 starting at block `0x2f8a00`.
This device has **no `init_boot`**.

## Traps already paid for

**The window of RAM.** `phys_base = 0xb0000000`, `mem_size = 0x30000000`
(ends at `0xe0000000`). Four rules, each learned by a reset or a panic:

- it must contain the splash framebuffer, because the early console maps
  `VA=PA` inside the window;
- it must start above the firmware's own memory: the kernel image is written
  to the start of the window, and overwriting the hypervisor at
  `0x80000000+0x600000` resets the phone;
- it must end in memory that exists: XNU takes its first heap pages from the
  *end* of the window, and a window ending in the hole hands them to nothing
  (`Undefined kernel instruction`, pc inside the physmap);
- it must not **contain** a carve-out or a hole in the middle: the VM hands
  out pages across the whole window, and the first access to a page it took
  from `0xe0000000`+ is a synchronous external abort (`Kernel data abort`,
  `far` inside the physmap of `qheebsp_reserved_region`). The previous 1.12
  GiB window had `0xe0000000..0xea000000` (the first bank's firmware islands)
  and `0xea000000..0xf4600000` (the gap between the banks) in the middle;
  launchd ran for minutes before an allocation landed there.

`0x30000000` is the largest window that ends at the first carve-out. Smaller
is not safe either: the bootstrap VA window is sized from `mem_size` in
256 MiB segments (`arm_vm_init.c`), and the early page tables run out below
768 MiB.

The **physmap slide** comes
from `/chosen/random-seed`, so a random seed makes the boot a coin flip
(about one host boot in three dies); `boards.py` pins the seed and `ADT_SEED`
overrides it. Do not use the biggest free hole (`0xbab00000+597 MB`): the
framebuffer falls outside it.

**Page size: 16 KiB, and the three pieces must agree.** `ID_AA64MMFR0_EL1`
reports `TGran16=1` (measured 2026-10-23; the menu prints it as `tg16`), so
mondrian runs the granule iOS is built for. These are the failures that cost
time:

| symptom | cause | where |
| --- | --- | --- |
| `disallowing unsupported code signature page shift: 14`, then launchd cannot load `libSystem` | the dyld cache's code directory is 16 KiB; a 4 KiB kernel refuses it (and would panic on a non-16 KiB-aligned hash offset) | `0001` (`__ARM_16K_PG__`), `tools/boards.py` |
| `LOADER ramdisk overlaps kernel memory` | `virt_base` must sit one L2 block (32 MiB) below the text, so the kernel image reaches past a fixed 32 MiB scratch offset and the ramdisk copy overwrites the payload it reads from | `shim/loader.c` (unpack at the top of the window) |
| no console at all after the shim | the granule is `BOARD_PG_SHIFT`: TCR TG0/TG1, 2048-entry tables, 32 MiB blocks | `shim/board.h`, `shim/mmu.c` |

The 4 KiB era left `0056` (commpage), `0057` (zone map VA) and `0062` (32 MiB
low-globals reservation) in the series; they still apply and are harmless.

**Instructions the platform does not have.** The kernel was once built with
`-march=armv8.5-a+crypto`, which emits 226 RCpc `ldapr`s; this board's cores do
not implement RCpc or pointer authentication, so the phone raised an undefined
instruction while QEMU's `-cpu max` (which implements every optional feature)
did not. Build for the board's own ISA, and remember that QEMU emulating
everything can hide exactly this class of bug.

**QHEE owns the physical timer.** Writing `CNTP_CTL_EL0` from EL1 is reported
as an *undefined instruction* (EC 0, not the EC 0x18 a trapped sysreg would
give) — patch `0061` drops the write. The virtual timer only fires once the
guest unmasks it for EL1 (`CNTV_CTL_EL1 = ENABLE | EL1IRQEN`, patch `0069`);
`CNTV_*`, `CNTKCTL_EL1` and `DAIF` are all accepted. There is no RTC service,
so `IOKitInitializeTime()`'s 30 s `IORTC` wait never expires and has to be
skipped on this board.

**Anything mapped with `ml_io_map()` before `STARTUP_SUB_KMEM` dies.** It is a
bootstrap mapping taken from `virtual_space_start`; once the VM owns that
address space the device is mapped nowhere and the next read is a bus abort
(`fault_code=0x10`, `FSC_SYNC_EXT_ABORT`). `0087` re-maps GICD/GICR through
`ml_io_map()` after the VM is up; the early framebuffer survives only because
`0062` keeps a reserved low-global alias for it.

**Never free the panel's memory.** The ABL leaves MDP → DSC → DSI scanning a
reserved buffer, so a linear framebuffer exists — but the boot arguments
describe the whole window as RAM. The frames must be initialized and then
kept off the free list (`mondrian_page_is_screen()` in `pmap_startup()`).
Stepping `pmap_next_page()` over the hole instead breaks the invariant that a
page's physical address is derived from its *index* in `vm_pages`
(`ppnum == VM_PAGE_GET_PHYS_PAGE(m)` assert in `vm_page_init`).

**Contiguous memory comes in small runs.** With 4 KiB pages
`kmem_alloc_contig(1 MiB)` never returned (256 pages); 128 KiB (36 pages)
did. Size descriptors and bounce buffers to what the zone map can give — the
UFS host asks for 144 KiB (nine 16 KiB pages) and gets it.

**The ABL does not hand the ramdisk over.** It gunzips it, and the bytes at
`/chosen/linux,initrd-start` are not the payload. The payload travels
**appended to the shim image**, which is the one segment copied raw. A 16 MB
image drops on the fastboot USB link, so the payload is LZ4-compressed
(15.3 → 6.7 MB) and unpacked by `shim/lz4.c`.

**Booting from UFS is not the same as booting from fastboot.** The ABL leaves
the UFS powered when it boots the normal way and powers it down in fastboot;
either way the kernel now brings the host up itself (`0074`–`0076`).

**fastboot serves 768 MiB per download and cannot split a raw image.** The
bootloader reports `max-download-size: 805306368`, and fastboot's answer to a
bigger raw file is to resparse it, which wants to read the partition back:
it fails at once with `fastboot: error: Failed reading from userdata` (the
name in the message is the partition, not a file). Flash an Android sparse
image instead (`tools/mk-simg.py`, or `tools/flash-root.sh`, which converts
anything over 768 MiB by itself): fastboot then sends it in `-S` chunks and
the root's zero tail costs nothing. 11 GiB of root take about five minutes.

**Kernel timeouts stop after userland starts.** Threads paced by
`tsleep(timeout)` wake once and never again (2026-10-25: the sampler printed one
line, the log flushed one 8 KiB batch). Pace periodic work from work that runs,
e.g. `mondrian_ufs_strategy()` (`0100`), or with `delay()`.

**The console is a ring with a cursor block.** The newest line is the one above
the cursor marker; reading then continues downward and wraps to the top. The
shim `LOGVIEW` currently faults synchronously at `STAGE ufs`; extract the ring
through a compatible recovery and ADB instead.

**dyld ignores `DYLD_INSERT_LIBRARIES` unless the MAC policy named exactly
`AMFI` answers `__mac_syscall` 0x5a.** Any other name returns `ENOPOLICY`;
dyld then drops the variable silently (no error, no crash, the process stays
healthy) and the library never loads. `0108` registers `AMFI` and allows
everything for 0x5a and 0x60.

## UFS bring-up, the sequence that works

UFS 3.1 host at `0x1d84000`; the sweet driver's register names still exist but
the UTRD is 16 dwords and the PRDT entries are 64-bit. What the working boot
does:

1. power the GCC branch for the host (`0x870`: BCR `0x87000`, AXI `0x87018`,
   AHB `0x87020`, UniPro `0x87064`, ICE `0x8706c`, PHY_AUX `0x870a4`,
   AGGRE `0x870d4`) — without it every register reads 0 and `HCE` does not
   stick;
2. take over the transfer list at a bounce buffer and verify the readback
   before ringing a doorbell; stop the list and wait before changing its base;
3. `hce 0x1 hcs 0x10f cap 0x1587031f ver 0x300`;
4. the device answers NOP OUT/IN but every LU is NOT READY with power mode
   `0x33` (PowerDown). Wake it with READ ATTRIBUTE `bCurrentPowerMode`, then
   **START STOP UNIT with power condition ACTIVE (CDB byte 4 = 0x10) on the
   UFS device well-known LUN `0xd0`**, then poll TUR on LUN 0. Power mode goes
   to `0x11`. Do not restart the link; the firmware state is adopted;
5. GPT header at LBA 2, `EFI PART`, `userdata` found, `BSD root: ufsroot0`.

Wait loops are spin counts, not `delay()`: the timer interrupt was not
delivered when this was written, and a wait that never completes has to be
non-fatal and dump `hcs/is/dbr` plus the UTRD.

The driver is read-only (`mondrian_ufs_write()` returns `EROFS`) and its
commands do not touch the medium. **Known debt:** `ufs_find_partition()`
bounds the entry table with `nent * esz > BOUNCE_SIZE`, a 32-bit product that
a corrupt table can wrap; guard with `nent > BOUNCE_SIZE / esz` before
multiplying, in the same patch that enables writes.

## Display

The panel does not need a driver for the lock screen: the ABL brings up
DSI/DSC/MDP and keeps scanning the reserved buffer, so the console and the
userland framebuffer driver get a plain linear 1440x3200 framebuffer. The panel
is 120 Hz; the iPhone X userland and CoreAnimation run at 60 (no ProMotion), so
`mondrianfb_hz=60` is the first target and 120 needs ProMotion.

- `0083` keeps the panel's frames off the free list (see the trap above).
- `0085` ports sweet's IOSurface + IOMobileFramebuffer pair to `AppleCLCD` on
  `/arm-io/disp0`; backboardd swaps are observed and the lock screen renders.
- Sweet's `0056` (present at most every few vsyncs) and `0079`
  (`RequestPowerChange`, the panel-off fade that the power button uses) have
  to be rebased onto the mondrian framebuffer driver when they are needed.

A fallback MDSS/DSI driver is only needed if the scanout ever stops.

## Boot menu and dual boot

`shim/menu.c` + `shim/menu_logos.h` (rasterized by `tools/gen-menu-logos.py`
from vector sources), preview in `docs/menu-preview.png`. Current build:
full-screen page, one card per choice, Font Awesome apple and the Material
bugdroid head at native size with 4-bit coverage, title/labels/countdown in
white, selection as a ring, and a selection change repaints only the two card
borders so the switch is immediate.

**Keys (SPMI).** The arbiter is version 7: observer channel stride `0x20`,
APID map at `core+0x2000+4n`, owner table at `cnfg+4n`. The status bits:
`KPDPWR` = bit 7 (power), `RESIN` = bit 6 (volume down — which is why the tree
has no `vol_down` gpio node), volume up = PM8350 GPIO6 on its own peripheral
page `0x8d`, level bit 0, held LOW. A PMIC gpio is its own peripheral page
(`0x88 + index - 1`), so do not map an index without the page table. The PON
node has no `__symbols__` label on these trees; find it by the compatible
string containing `pon`. Rising edges drive the menu, so one press does not
cycle twice; bit 0 rising confirms.

When the probe refuses it prints `spmi code N ver XXXXXXXX` (1 no arbiter,
2 reg-names, 3 regions, 4 missing, 5 count, 6 no pon, 7 pon ppid, 8 pon apid,
9 no gpios, 10 gpio ppid, 11 gpio apid, 12 vol_up phandle), so one photo names
the defect.

**Phases.** v0–v0.4 (draw, then keys) are done. Next: reboot from inside the
kernel (the shim already does `PSCI_SYSTEM_RESET` + `PSHOLD` + restart reason
in IMEM; a "MACH Reboot" still hangs, so validate the WDT reset first), then
the A/B switch through the 4 KiB `misc` BCB — unproven with this ABL, and
`shim/ufs.c` is read-only SCSI, so a WRITE(10) there might do the whole
switch without the kernel. `boot_a` stays untouched at all times:
`fastboot boot` (power + volume down) is the rescue path.

## Other ports worth reading

- **`UniXNU/UniXNU`** — iOS *and* macOS on non-Apple arm64, same xnu-8796.141.3
  and the same 4 KiB pages. Its `native-4k-bootstrap-capacity.patch` is the
  `pmap_map_bd` fix now merged into `0001`; `native-4k-user-abi.patch` is for
  later (four places where XNU hardcodes 16K decide what userspace sees). It
  also documents the UFS LU wake used by `0082`.
- **Bergamota / Chlorophyll / HackiOS** — Bergamota documents a working CPU
  fallback; Chlorophyll targets Adreno 630. HackiOS's iOS 16.5 hook disables
  containermanagerd personas; `0106` redoes this for 20H392 with runtime method
  checks, not borrowed shared-cache offsets.
- **`palazik/ios-dodge`** — patch-per-lesson series: local TLB flush, timer
  quiesce, *do not touch* `CNTP_CTL_EL0` at handover, physmap alignment
  padding, framebuffer block-descriptor alignment.
- **`mytiantian001/iPadOS-nabu`** — same CPU generation; `cpus=1` as the safe
  default, and the 4 MiB persistent ring at the end of `userdata` readable
  from recovery.
- **`MakrSas/ios-topaz`** — boots to the home screen on SM6225; its walls are
  the missing SGI/timer interrupt (fixed by preparing the GIC in the shim)
  and ARMv8.0 without LSE/RCpc (needs an emulation path for the userland).
- **`Gsjsjzhznsz/ios-raphael`** — reaches the lock screen; a CPU `compatible`
  mismatch hung its bootstrap, and a DWC31 USB hang is the class of bug the
  USB port will meet.
- **`Log1nYT/ios-sweet` (venus)** — 23 patches past the sweet series: DWC3
  probe with GCC clock gates, SPI touch on a QUP, PMIC keys, real battery over
  SPMI, and echoing the previous boot's log into the console.

## Sweet (upstream) notes

The sweet half of this fork is the working reference: stock bootloader →
`fastboot boot` → shim → XNU → UFS → HFS+ root in `userdata` → launchd →
backboardd + SpringBoard. Its patch series in `xnu/patches/` is the source for
every generic piece this port reuses, and its README documents the boot
arguments, the iOS root image build and the diagnostic patches. `main` in this
fork is fully absorbed into the upstream history and is kept only as the
upstream/sweet reference — never the target of work.
