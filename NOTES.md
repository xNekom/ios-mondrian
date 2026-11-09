# ios-mondrian — engineering notes

Port of [ios-sweet](https://github.com/dipa-studio/ios-sweet) to the **POCO F5
Pro / Redmi K60** (`mondrian`, Qualcomm SM8475 / Snapdragon 8+ Gen 1): Apple's
open-source XNU (xnu-8796, the iOS 16 generation) running the unmodified
iPhone X iOS 16.7.16 userland.

This file holds the state of the port and the facts that were expensive to
learn; the work list, the hardware delta and the partition rules are in
`docs/MONDIAN_PORT.md`. The upstream `sweet` port is the reference
implementation and is not re-described here: `xnu/patches/` is its record.

## State (2026-11-09)

- **Boot chain.** ABL → `fastboot boot` (or the `boot_b` image) → shim → XNU.
  The shim reads the live device tree, unpacks the LZ4 payload and jumps. The
  console draws into the splash framebuffer the ABL leaves at **0xB8000000**
  (1440x3200, stride 5760). Build the shim with `SMALL_SHIM=1`
  (`tools/phone-deploy.sh` does): the full shim's `test_gic()` storms and the
  phone shows IRQ lines and no kernel.
- **Two loader modes, one slot budget.** `fastboot devices` answers in the
  bootloader's fastboot (power + volume down), which accepts `fastboot boot`,
  and in **fastbootd**, which the BCB command `boot-fastboot` selects and
  which answers `Unrecognized command boot`. ABL spends one retry per boot,
  so after seven the slot reads `slot-unbootable:b:yes` and refuses every
  image; `fastboot set_active b` resets flag and budget without writing a
  partition.
- **16 KiB pages.** The SoC reports `TGran16=1` in `ID_AA64MMFR0_EL1`, so
  shim, payload and kernel all run the granule iOS is built for:
  `__ARM_16K_PG__`, `ARM_PGSHIFT` 14, 32 MiB L2 blocks, the Apple VA layout.
- **Kernel.** Gets through `arm_init`, VM init, `kmem_range_init`, IOKit, the
  scheduler and AMFI into `bsd_init`. The GIC is remapped after the VM takes
  over; the vtimer PPI (27) needs its active state ended and its Group 1
  secure modifier cleared (`0116`), and `0173` arms `CNTV_TVAL` before clearing
  IMASK or the level-sensitive PPI re-enters for ever before the UFS probe.
- **UFS, end to end.** Host clocked, NOP/QUERY answered, the LU woken through
  the device well-known LUN, the GPT parsed, `userdata` located, HFS+ root
  mounted and `launchd` exec'd. The console ring is armed at the end of the
  UFS probe, before `vfs_mountroot` (`0174`), so a failed mount leaves its
  error on disk.
- **USB, both directions.** `usb=1` probes the DWC3 the ABL leaves powered;
  `usb=2` runs the gadget: an ECM Ethernet device at 192.168.7.2 with a control
  channel on udp/5141. `tools/usb-ring.py` dumps the ring, photographs the
  panel (`screen`), injects `tap`/`swipe`/`key`, prints the memory breakdown
  (`mem`) and returns to the bootloader (`reboot`); `tools/ios-usbnet.sh` sets
  the host up and streams udp/5140. No recovery dump and no buttons.
- **iOS userland.** `0089` handles root-auth ENOTTY; launchd reaches 150
  processes. `0112` injects the UI dylib per daemon (`mondrian_ui_hook`: 1
  containermanagerd, 2 backboardd, 4 SpringBoard); `hook=7` loads all three.
- **Writable root.** `0090` adds WRITE(10), SYNCHRONIZE CACHE and the write
  path; `DKIOCISWRITABLE` must agree or HFS disables writes.
- **Display and UI.** The home screen redraws at the panel's 60 fps on the
  iPhone X's 1125x2436 canvas, and the compositor commits in bursts, so the
  tick holds two finished records (`0282`). A static screen presents nothing:
  `present 0/s` with the panel still scanning is idle, not stalled. CoreAnimation
  needs `TimingElements`/`ColorElements` and an `IOAcceleratorES` service
  (`0114`); the dylib forces activation and skips Setup, and GPU writes memory
  once `CP_SET_SECURE_MODE(0)` retires.
- **Memory, the real blocker.** The window is 864 MiB
  (`0xaa000000+0x36000000`) and iOS 16 wants more: `free` sits at 14-24 MiB,
  `wire` at ~454, and jetsam SIGKILLs `iconservicesagent`, which also fails
  to opt into its 50 MB high watermark ("22"), so it dies at load; the App
  Library draws empty cards and an app launches to a black window. The wire
  is ~165 MiB of compressor segments (38k source pages at ~4:1) and ~200 MiB
  of GPU surfaces, neither a leak. There is no swap to drain: `swapped 0`,
  zero swap space, so the window is the whole budget.
- **A window above 4 GiB boots.** In QEMU the kernel reaches the panel driver
  with its RAM at `0x100000000`, as far as the low window gets
  (`docs/QEMU_TESTING.md`). The one casualty was `phystokv(0xb8000000)`: the
  console fallback panics when the splash is outside the window, and is now
  conditional (`0295`).

Current blockers, in order:

1. **Memory.** The high bank is the fix; the work list is in `docs/MONDIAN_PORT.md`.
2. **Idle sleep and gestures.** The idle timer sleeps the display
   (`mondrianunlock=1` re-requests the unlock); the home swipe starts at the edge.
3. **Buttons.** Power/volume-down on PMK8350 PON, volume-up on PM8350 GPIO6 not
   read yet.
4. **Rest.** Audio, modem and cameras: the daemons that abort
   (SiriTTSSynthesizer, KonaSynthesizer) want them.

## Building and booting

**Kernel.** `.github/workflows/xnu.yml` and both local builds
(`tools/build-kernel-local.sh` on the Mac, `tools/wsl/build-kernel.sh` on
Windows/WSL2, `docs/BUILD_LINUX.md`) fetch xnu-8796.141.3, reset the checkout
and apply `xnu/patches-mondrian/`; a skipped patch fails the run (the
workflow's "No skipped patches" step greps the log). Run `tools/apply-series.py`
(or `tools/check-patches.sh`) after touching the series: it names the patch in
seconds (`0161` was silently missing until 2026-10-28, `0157` carried its first
hunk). A mondrian build also needs the local `mondrian_gmu_fw.h`; `0184` stubs
the user-client surface without the CP profile. Artifacts and the KDK cache
live outside the reboot-cleared temp directory, and `DXB_DIR` must not contain
a space (`build.sh` uses it unquoted).

**Apple's clang builtins are load-bearing.** Without `__builtin_xnu_type_*`
(`tools/wsl/patches/0002` stubs them) every kalloc_type view is a data view, none
is kept, the iterator that follows asserts (`kalloc.c:1264`) inside
`kernel_bootstrap` (black panel, no ring), and `0008` returns when none was kept.

**`iig` trap.** A newer Xcode's `iig` regenerates the DriverKit stubs wrong
(`docs/MONDIAN_GPU.md`); seed them from a build made with Xcode 15.

**Image and deploy.** `tools/phone-boot.sh` builds if needed and boots
volatile; `tools/phone-deploy.sh` (push/install/backup/reboot) is the adb path
and refuses `boot_a` unless `BOOT_A=1`. `tools/qemu-ios.py` boots the same
payload; `--kernel` only feeds its decoder (`docs/QEMU_TESTING.md`).

**Boot arguments have a hard end.** `BOOT_LINE_LENGTH` (1024 since `0267`)
bounds the shim's payload header, `boot_args.CommandLine` and `kern.bootargs`,
and an argument past it does not exist, silently (measured, ring225:
`mondrianiconset=1` sat a few bytes past 608 and its pass never ran).

**Reading a boot.** `0096` tees kernel and `/dev/console` output into a 4 MiB
ring that `0174` arms before `vfs_mountroot`, so a failed mount still leaves the
log on disk. `mondrianfb_noconsole=1` stops painting the panel at the first
CoreAnimation swap, so a photo can show an earlier boot: the ring is the truth.
A previous boot is read by running the real kernel, then a dump kernel with
`mondriandump=1` and `mondriandumpmatch=` (`0099` splits the list).
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

**The window of RAM.** `phys_base = 0xaa000000`, `mem_size = 0x36000000`
(ends at `0xe0000000`, 864 MiB). Five rules, each paid for with a reset:

- it must contain the splash framebuffer (the early console maps `VA=PA`
  inside the window) and start above firmware memory: the kernel goes to the
  window's start, and overwriting `0x80000000+0x600000` resets the phone;
- it must start above the shim, **including the appended LZ4 payload**, because
  the loader wipes the window before it unpacks. `_end` is a runtime address,
  not an offset (symbols are PC-relative), and the magic `LZ4P` is `0x50345a4c`
  little-endian; reading it as `0x505a344c` left the base at `_end`, and the
  wipe kept the header and ate the frame;
- the base must be 32 MiB aligned, and `boards.py`/`shim/board.h` must be the
  window the shim passes: `mkadt.py` writes the pair into `/chosen` as
  `dram-base`/`dram-size`, and the shim puts it in `boot_args`. At
  `0xa8758000` (889 MiB, ADT at `0xa7400000/0x38b00000`) the loader jumped and
  the kernel died in `start.s` before its first `MONDRIAN EARLY` mark;
- it must end in memory that exists (XNU takes its first heap pages from the
  *end*) and not **contain** a carve-out or hole: the VM hands out pages across
  the window, and an access to one taken from `0xe0000000`+ aborts
  (`Kernel data abort`, `far` inside the physmap of `qheebsp_reserved_region`).

The bootloader's device tree is *not* a floor: keeping it (ends `0xb72ac000`)
cost 236 MiB and put the base 14 MiB under the splash, where the 16 MB kernel
landed on the framebuffer. The early page tables run out below 768 MiB.

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

The 4 KiB era left `0056`/`0057`/`0062` (commpage, zone map VA, 32 MiB low globals); they still apply.

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
`CNTV_*`, `CNTKCTL_EL1` and `DAIF` are all accepted. `0173` programs
`CNTV_TVAL` before clearing IMASK: the loader leaves the compare expired and
the level-sensitive PPI otherwise storms. There is no RTC service, so
`IOKitInitializeTime()`'s 30 s `IORTC` wait never expires and has to be
skipped on this board.

**Anything mapped with `ml_io_map()` before `STARTUP_SUB_KMEM` dies.** It is a
bootstrap mapping taken from `virtual_space_start`; once the VM owns that
address space the device is mapped nowhere and the next read is a bus abort
(`fault_code=0x10`, `FSC_SYNC_EXT_ABORT`). `0087` re-maps GICD/GICR through
`ml_io_map()` after the VM is up; the early framebuffer survives only because
`0062` keeps a reserved low-global alias for it.

**`ml_io_map()` never unmaps; the I/O submap is 8 MiB.** The touch command
DB (128 KiB) and RSC (64 KiB) were re-mapped per cmd-db lookup and rail vote,
and the next `kmem_alloc(..., 131072, KMA_NOFAIL)` panicked in `io_map`. Map a
window once (`0179`).

**Contiguous memory comes in small runs.** With 4 KiB pages
`kmem_alloc_contig(1 MiB)` never returned; 128 KiB did. Size descriptors to what
the zone map can give (the UFS host asks for 144 KiB).

**The ABL does not hand the ramdisk over.** It gunzips it, and the bytes at
`/chosen/linux,initrd-start` are not the payload. The payload travels
**appended to the shim image** as an LZ4 blob (`shim/out/payload.lz4p`, unpacked
by `shim/lz4.c`). Never write the blob over `shim/out/payload.bin`, the raw
payload: that truncates it to a header promising 0 bytes and the shim answers
`LOADER cannot unpack the payload`. `tools/check-shim-blob.py IMAGE` reads the
header back.

**Booting from UFS is not the same as booting from fastboot.** The ABL leaves
the UFS powered when it boots normally and powers it down in fastboot; either
way the kernel brings the host up itself (`0074`–`0076`).

**The shim is not a no-op, and it can hide kernel bugs.** The full shim runs
`test_gic()` before the jump: it arms `CNTV_TVAL`, storms until it gives up and
leaves the UFS warm. Behind it the kernel looked healthy; with `SMALL_SHIM=1`
the kernel arms the timer itself (`0173`) and wakes the UFS. Panel showing IRQ
lines and no `MONDRIAN EARLY` means the shim, not the kernel (`nm
shim/out/shim.elf | grep test_gic`).

**fastboot serves 768 MiB per download and cannot split a raw image.** A bigger
raw file is resparsed and reading it back fails; flash a sparse image instead
(`tools/mk-simg.py`), which fastboot sends in `-S` chunks.

**Kernel timeouts stop after userland starts.** Threads paced by
`tsleep(timeout)` wake once and never again; pace from work that runs (`0100`)
or `delay()`.

**The console paints the kernel log and scrolls.** The early console drew only
its own marks, so the boot looked frozen; `0210` paints the log, clears the
panel once first and scrolls half a screen at the last text row. `0213` moves
the painting into the log thread: from `console_write()` every line waited for
the framebuffer, and two CPUs printing at once painted over each other's rows.
`0005` registers the fbcon unconditionally, so text lands on the ABL Apple logo
from the first `printf`; the intended default is to leave the panel alone
unless `mondrianfb_console=1` (the ring keeps every line). The shim's
`test_ufs()` faults on a boot that came from fastboot (host powered down):
build with `SHIM_NO_UFS` (`LOGVIEW` implies it).

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
`mondrian-ufs-debug` skill.

Wait loops are spin counts, not `delay()`: a wait that never completes has to be
non-fatal and dump `hcs/is/dbr` plus the UTRD.

The write path is `0090` (WRITE(10), read-modify-write, SYNCHRONIZE CACHE).
**Known debt:** `ufs_find_partition()` bounds the entry table with
`nent * esz > BOUNCE_SIZE`, a 32-bit product a corrupt table can wrap; guard
with `nent > BOUNCE_SIZE / esz`.

**HFS+ corruption shows as `hfs_mark_inconsistent` on every metadata access.**
`fsck.hfsplus -fy` on a copy of the 16 GiB root names the damage: overlapped
extents, a bad volume bitmap and a wrong free-block count; repeat `-fn` until it
says `appears to be OK`, then push the changed blocks back. The volume is
non-journaled (`0x80000100`), so a hard reset dirties it again; once the damage
reaches the allocation-block count (`Invalid number of allocation blocks`) the
dump fails fsck and the root has to be rebuilt from a clean image. A zeroed
extents node (block 2178, `0x882000`) means the same; the live GPT is the single
`userdata`.

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

## Other ports worth reading

- **`UniXNU/UniXNU`** — iOS and macOS on non-Apple arm64: the bootstrap-capacity
  patch in `0001` and the UFS LU wake.
- **Bergamota / Chlorophyll / HackiOS** — CPU fallback, Adreno 630, the iOS 16.5
  persona hook that `0106` redoes.
- **`oosexgang/hakios-xnu-kernel`** — same `eagl.c`, one revision ahead (`docs/COREANIMATION_GLES.md`).
- **`palazik/ios-dodge`**, **`MakrSas/ios-topaz`**, **`Log1nYT/ios-sweet`** —
  local TLB flush, timer quiesce, `cpus=1`, home screen on SM6225, DWC3 clocks.
