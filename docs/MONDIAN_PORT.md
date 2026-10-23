# Porting ios-sweet to the POCO F5 Pro (mondrian)

`sweet` is a Redmi Note 10 Pro: Snapdragon 732G (SM7150), ARMv8.2, 16 KiB
pages, an LCD in DSC video mode, a Goodix touch on I²C and a PM6150.
`mondrian` is a POCO F5 Pro (the global Redmi K60): Snapdragon 8+ Gen 1
(SM8475), ARMv9.0, 4 KiB pages, an AMOLED on DSI D-PHY, a Goodix touch on
SPI and a PM8008.

Same project, same idea (stock iOS 16 userland on top of a patched XNU), very
different silicon. This document is the work list for the port: what is
already in place, what has to change, and where the numbers come from.

## What is already in this fork

| Piece | State |
| --- | --- |
| `tools/boards.py` | the board table (MMIO, memory, CPU topology, page size) for sweet and mondrian |
| `tools/mkadt.py --board` | builds the Apple Device Tree for either board |
| `tools/mkpayload.py --board` | packs the kernel, with the payload magic and the L2 block size of the board |
| `shim/board.h`, `shim/build.sh BOARD=` | the bare-metal shim for either board |
| `shim/fdt.c` | a device tree parser, so the board table can be filled in from the live device |
| `xnu/patches-mondrian/0001` | the XNU machine config for SM8475 (ARMv9.0, 4 KiB pages, GICv3) |
| `xnu/patches-mondrian/0002` | the master config of the board (`config/MASTER.arm64.mondrian`) |
| `xnu/patches-mondrian/0003-0055` | the generic half of the sweet series, ported (RAM disk root, AMFI, HFS+, BearSSL, console, crash log, HID, SMP, identity) |
| `tools/port-series.py` | ports a patch of the sweet series to the mondrian series and flags the hardware parts |
| `tools/apply-series.py` | applies a series to an xnu tree in seconds and reports what does not apply |

The ported series applies cleanly: `tools/apply-series.py` reports
**55/55** against a fresh xnu-8796.141.3 tree.

The patches that are **not** ported are the ones that talk to the hardware
of the sweet phone. They are listed in `HARDWARE_PATCHES` of
`tools/port-series.py` with what each of them needs, and they are the work
list below.

## Safety: what can and cannot brick the phone

The phone's boot chain is Qualcomm firmware below the Android images:
`xbl` → `xbl_config` → `abl` → `tz`/`hyp`/`uefisecapp`/modem. An image in
that chain cannot be repaired by the OS or by fastboot — on this device
the only way back is EDL with an authorized Xiaomi account — so it stays
out of bounds permanently. Everything the port writes lives above that
chain, where the stock fastboot ROM can restore any image.

### Partition policy

Written — the allow-list; everything else is off:

| Partition | Role | Extra rule |
| --- | --- | --- |
| `boot_b` | the shim slot | the routine target of the port |
| `boot_a` | stock Android, the escape hatch | deploy tooling refuses it (`phone-deploy.sh install` needs `BOOT_A=1`); a verified backup precedes any write |
| `vendor_boot` | the shim reads its live device tree out of it | dump verified by SHA256 first |
| `misc` | the A/B boot-control block; dual boot v2 writes it from the kernel | wrong content only selects the wrong slot; `fastboot --set-active` fixes it without flashing anything |
| `init_boot`, `recovery` | untouched so far | the same safeguards whenever a write is actually needed |
| `userdata` | the iOS root | erasing Android user data here is acceptable and recoverable; `tools/flash-root.sh` writes it and asks first |

Repeated volatile `fastboot boot` runs — including every failure and every
panic — touch no partition at all, and a slot switch (`fastboot
--set-active a`) only marks state; neither is part of the write count.

Never written — the deny-list, an irreversible brick:

`xbl`, `xbl_config`, `abl`, `tz`, `hyp`, `uefi*`/`uefisecapp`, `modem*`,
`persist`, and every other low-level image the stock ROM ships. Nothing in
this port needs them, and the dual-boot plan runs entirely inside the
allow-list: the menu is in the shim, the slot switch is a `misc` write.

Read-only as well, because nothing needs them and a bad copy can break
verified boot or device-tree delivery: `vbmeta`, `dtbo`.

### A definitive write, in graded steps

1. **Volatile proof first.** `fastboot boot` the same image. It writes no
   partition; a bad image leaves the phone in fastboot and nothing worse.
2. **Name the target.** `fastboot getvar current-slot`; the write pins to
   that `boot_<slot>`, `boot_a` never by accident.
3. **Verified originals.** Dump the target partition, pull it to
   `backup/`, record it in `SHA256SUMS`, and check the sum before writing.
   (The on-phone copy sits in `/data/local/tmp` and dies with the next
   `userdata` wipe; the copy on the workstation is the durable one.)
4. **Write, read back, then commit to booting from it.** Verify the
   flashed partition by hash, reboot once, confirm the slot the next boot
   came from.
5. **Keep the disaster baseline.** The complete stock fastboot ROM of this
   exact model restores every allow-list partition; keep it on disk before
   the first definitive write.

Two rules cover the other failure mode — writing to the wrong place:

* **The shim takes its addresses from the device tree the bootloader
  passed**, not from constants. The framebuffer comes from the splash
  region of the device tree, the UFS host from the `qcom,ufshc` node. If
  the device tree does not name a framebuffer, the console stays off and
  the shim writes nothing at all. On sweet the measured constant is only a
  fallback; on mondrian (`BOARD_FB_FROM_DTB`) there is no fallback.
* **No image is built from guessed numbers.** `tools/boards.py` marks the
  fields that are still a guess (`Board.provisional`), and `mkadt.py` and
  `mkpayload.py` refuse to build for such a board:

  ```
  $ python3 tools/mkadt.py mondrian.adt --board mondrian --highmem
  mkadt.py: the board "mondrian" is not measured yet.
    Still a guess: fb=0x9c000000, fb_size=0x1700000, ...
  ```

  The values are cleared when a shim dump of the real phone is fed in
  (`--facts facts.txt`), so the sequence is: boot the shim without a
  payload, read the screen, fill in the table.

## The hardware delta

Everything below is taken from the public sources listed at the end; the
values that still have to be read from the device are marked **TODO**.

| | sweet (SM7150) | mondrian (SM8475) |
| --- | --- | --- |
| CPU | 2x Cortex-A76 + 6x Cortex-A55, ARMv8.2 | 1x Cortex-X2 + 3x Cortex-A710 + 4x Cortex-A510, ARMv9.0 |
| Page size | 16 KiB (`__ARM_16K_PG__`) | **4 KiB** (`PAGE_SIZE=4096` in `build.config.msm.mondrian`) |
| Page tables | L2 block = 32 MB | L2 block = 2 MB (`ARM_4K_TT_L2_SIZE`) |
| Pointer auth | none | none (compile plain arm64, like sweet) |
| GICD | 0x17a00000 | **0x17100000** |
| GICR | 0x17a60000, 2 RDs, stride 0x20000 | **0x17180000, 8 RDs, stride 0x40000** |
| Timer INTID | 19 (Qualcomm PPI numbering) | 19 (same numbering) |
| UFS host | ufshc@1d84000, UFSHCI 2.1 | ufshc@1d84000, **UFS 3.1** (different host IP) |
| Touch | Goodix GT9896 on I²C (GENI SE) | **Goodix on QUPv3 SPI** (`xiaomi,m11a-spi`, SE4 @ 0x990000) |
| Buttons | PM6150 PON / SPMI | **PM8008** (PMR735A + PM8350B); volume up on PM8350 GPIO6 |
| Display | 1080x2400 LCD, DSC video mode, cont_splash_region at 0x9c000000 | **1440x3200 AMOLED, DSI D-PHY** (MDSS 0x0ae00000, DPU 0x0ae01000) |
| Memory | 0x80000000 + 2 GiB, 0x100000000 + 0xfcc00000 | **TODO**: read the live device tree |
| PMIC rails | PM6150 LDO11 (touch), fuel gauge | **TODO**: PM8008 rails (L2C, L3C, L9C in the device tree) |

Sources: see [References](#references).

## The window of RAM (2026-10-21, measured)

The window is the block of physical memory the kernel gets: it decides
where the kernel image is written, what the kernel's physical aperture
looks like, and what the framebuffer console can reach. Three rules, all
learned the hard way:

1. **It has to contain the splash framebuffer** (0xb8000000 on this phone).
   The kernel's framebuffer console is mapped VA=PA inside the window; with
   the framebuffer outside, the kernel dies before it prints anything.
2. **It has to start above the firmware's own memory** at the bottom of the
   bank. The hypervisor is at 0x80000000+0x600000
   (`/reserved-memory/hyp_region`) and the kernel image is written to the
   start of the window: overwriting the hypervisor kills the secure world
   and the phone **resets** instead of booting.
3. **It has to end in memory that exists.** This phone's RAM has a hole:
   the live tree says `0x80000000+0x6a000000` and `0xf4600000+0xba00000`,
   so **0xea000000..0xf4600000 is not RAM**. XNU takes its first heap pages
   from the *end* of the window (`static_memory_end = physmap_base +
   memSize`), so a window that ends inside the hole gives the first heap
   pages to memory that is not there: the writes are lost and the kernel
   jumps to a corrupted pointer. That was the phone's panic
   ("Undefined kernel instruction", pc inside the physmap).

So the mondrian's window is:

    phys_base = 0xb0000000
    mem_size  = 0x46000000        # ends at 0xf6000000, in the second bank

There is also a **floor**: below 0x3a000000 the physmap no longer fits next
to the kernel's own image and the boot dies in `pmap_map_bd`. At
0x46000000 the host boots with every slide tried.

Measured on the host with the same kernel (`tools/qemu-ios.py`; the window
is chosen with the `QEMU_PHYS_BASE`/`QEMU_MEM_SIZE` environment variables,
so no phone is needed to try a window):

| window | result |
| --- | --- |
| `0xb0000000 + 0x46000000` | **boots clean** |
| `0xb0000000 + 0x4d000000` (the sweet's) | boots clean **on the host only**: it ends at 0xfd000000, inside the phone's hole |
| `0xb0000000 + 0x3a000000` | boots clean (ends just before the hole) but needs a lucky slide |
| `0xb0000000 + 0x30000000` | panic in `pmap_map_bd` with every seed tried |
| `0xbab00000 + 0x25500000` | panic in `pmap_map_bd` |
| `0xb8000000 + 0x4d000000` | data abort before the console |
| `0x80000000 + 0x25500000` | panic in `pmap_map_bd` |
| `0xb0000000 + 0x25500000` | panic in `pmap_map_bd` |

XNU's arm64 PE builds the physical aperture from `gPhysBase`/`gPhysSize`
(`osfmk/arm64/arm_vm_init.c`, `arm_vm_physmap_init()`); a window that does
not fit that shape leaves the kernel without a usable map.

**The physmap slide makes the boot a coin flip.** `arm_vm_physmap_slide()`
moves the physmap by up to 1 GB, and the offset comes from the random seed
the device tree hands the kernel (`/chosen/random-seed`). With a random
seed about one host boot in three dies in `pmap_map_bd`, and which one
changes every time. The mondrian therefore pins the seed
(`tools/boards.py`, field `seed`; `ADT_SEED=<hex>` overrides it), and the
table above was measured with a pinned seed. **The earlier "only this base
boots" conclusion was measured with a random seed and is not trustworthy:
redo the base bisection with a pinned seed.**

**Do not use the biggest free hole.** `0xbab00000 + 597 MB` is clear of
every carve-out, but the framebuffer falls outside it.

The board table (`tools/boards.py`) and the shim (`shim/board.h`) hold the
window; the shim checks the live device tree agrees that it is inside a
memory region and says so on the screen.

### The memory of this phone (from the live device tree)

| what | value |
| --- | --- |
| `/memory` | `0x80000000+0x6a000000`, `0xf4600000+0xba00000`, four above 32 GB |
| usable RAM per the bootloader | 1.85 GB (`ddr_size` says 12) |
| `/reserved-memory` | 38 carve-outs: hypervisor 0x80000000+0x600000, AOP, SMEM, modem 0x8bc00000+0x13200000, splash 0xb8000000+0x2b00000, tags, QTEe |
| biggest hole | `0xbab00000 + 597 MB` (does not boot: no framebuffer) |
| framebuffer | 0xb8000000, 1440x3200, stride 5760 |
| GIC | GICD 0x17100000+0x10000, GICR 0x17180000+0x200000, redistributor stride 0x40000 |
| virtual timer | INTID 19 (no `virtual-timer-intid` in the tree) |
| UFS host | 0x1d84000 (`ro.boot.bootdevice` = `1d84000.ufshc`) |

## Getting the phone to do things

| what | how |
| --- | --- |
| run the kernel | the phone in fastboot (power + volume down), then `tools/phone-boot.sh` |
| write an image to the boot partition | `tools/phone-deploy.sh push` + `install` (asks first) |
| a root shell | `adb pair <ip>:<port> <code>` (Android wireless debugging) + `adb root`; the build is `userdebug` |
| recover from a boot loop | recovery (power + volume up), then `dd if=/dev/block/by-name/boot_a of=/dev/block/by-name/boot_b bs=4M` |

`fastboot boot` writes no partition, so the phone keeps its Android
installation; the original boot image is also kept at
`/tmp/boot-orig-b.img` (sha1
`89a1b3dfced4a6e4312925641daf51133a70f6ff`) and on the phone at
`/data/local/tmp/boot-orig_b.img`.

**The kernel panics after its console comes up** (`Undefined kernel
instruction: pc=0xfffffff00740c4f`), and the same kernel boots clean in
QEMU with the same window. That is the open item. A first guess (stale RAM,
wiping the memory above the window) was wrong: XNU's dynamic memory is a
virtual range whose pages come from the free list, and the wipe crossed
4 GB into a hole the device tree does not describe, so the shim faulted.
The wipe was removed; the full panic is the next thing to read (the console
scrolls, so a photograph has to cover the whole screen).

## The work list

Ordered so that every step is testable on its own. The first four steps need
no phone.

### 1. The XNU machine config — done

`xnu/patches-mondrian/0001-mondrian-machine-config.patch` adds the
`MONDRIAN` machine config: `pexpert/pexpert/arm64/MONDRIAN.h`, the
`MakeInc.def` entry (`-march=armv8.5-a+crypto`, plain `arm64` because the
X2/A710/A510 have no pointer authentication), the cache line sizes, and the
GICv3 Group 1 interrupt path (`sleh_irq`, `pe_init_fiq`) that a two security
state GIC needs.

ARMv9.0 is binary compatible with the ARMv8.5 baseline, so the kernel is
compiled for armv8.5-a and runs on the X2. XNU 8796 has no LPA2, so it uses
39-bit virtual addresses, which ARMv9 still allows.

**The build works** (CI run `39457133108`): the artifact is a plain arm64
Mach-O with not a single PAC instruction, and the board identifiers are in
it (`MondrianPlatformExpert`, `IONameMatch = 'xiaomi,mondrian'`, ...).

**Check:** `gh workflow run xnu.yml -R xNekom/ios-mondrian -f board=mondrian`
must produce `kernel.development.mondrian`.

#### 1.1 The 4 KiB page tax

This is the part of the port that is not a rename. With 4 KiB pages:

| What | 16 KiB (sweet) | 4 KiB (mondrian) |
| --- | --- | --- |
| L1 entry covers | 64 GB | 1 GB |
| L2 block covers | 32 MB | 2 MB |
| the physmap needs | 1 L1 entry for 4 GB of RAM | 4-5 L1 entries |
| the commpage check | not compiled | asserts the commpage is above the user VA |

The commpage assertion (`osfmk/arm/pmap/pmap.c`, the `ARM_PGSHIFT == 12`
branch) cannot hold on this board: the MacOSX platform gives the user a
140 TiB VA, and the commpage has to stay mappable by the userland. Patch
`xnu/patches-mondrian/0056` replaces it with the check that does hold: the
commpage and its 1 GiB nesting region (which is reserved in every user
address space) share an L1 entry.

The alternative, cleaner in principle, is to build the **iPhoneOS** platform
instead of the MacOSX one: its user VA is 63.75 GB, the original assertion
holds as it is, and the platform matches the userland. The sweet port uses
the MacOSX base, so this is a bigger change than a patch.

**The early boot was the remaining problem, and it was the address
layout.** With 4 KiB pages the kernel faulted on the first instruction of
`arm_init` (`ESR 0x21 / 0x86000004`, a level 1 translation fault) even
though the bootstrap page tables were correct:

| | 16 KiB (sweet) | 4 KiB (mondrian) |
| --- | --- | --- |
| `TCR_EL1_BOOT` | T0SZ = T1SZ = 17, 47-bit VA | T0SZ = T1SZ = 25, 39-bit VA |
| TTBR1 window starts at | `0xFFFF800000000000` | `0xFFFFFF8000000000` |
| kernel link address | `0xFFFFFE0007004000` (inside) | the same address (outside) |

The build runs with `PLATFORM=MacOSX`, so `makedefs/MakeInc.def` picks
`ARM64_LINK_ADDR = 0xFFFFFE0007004000`, low globals at
`0xFFFFFE0000000000` and `-DARM_LARGE_MEMORY=1`. That whole layout only
fits in a 47-bit VA: with 4 KiB pages the kernel address is in the hole
between the TTBR0 and TTBR1 windows, so the MMU never walks its tables.
Patch `xnu/patches-mondrian/0001` now gives MONDRIAN the device layout
(`ARM64_LINK_ADDR 0xFFFFFFF007004000`, `-UARM_LARGE_MEMORY`).

Measured with the QEMU gdb stub (`--gdb`, stop on the exception vector,
read the system registers): `TTBR0_EL1 0xb0176000`, `TTBR1_EL1
0xb0177000`, `TCR_EL1 0x22a5192519` (4 KiB granules, 39-bit VA),
`SCTLR_EL1` M = 1 - and the tables populated exactly where expected. The
tables were right; the address was not in any window.

The earlier "sweet 4 KiB" control (`exp/sweet-4k`) does **not** contradict
this: its `TCR_EL1_BOOT` is still `0x226511a511` (T0SZ = T1SZ = 17,
TG0 = TG1 = 16 KiB), so it was a 16 KiB kernel with a 47-bit VA. The
mondrian build is the first real 4 KiB kernel in the tree.

The console alias that patches 0010/0012 install for the world after the
bootstrap TTBR0 lives at `LOW_GLOBAL_BASE_ADDRESS + 2 MB` for the same
reason: the device layout has no reserved L1 entry at
`VM_MIN_KERNEL_ADDRESS`, but `gVirtBase` and the low globals share one.
The panel is 18 MB, so with 2 MB blocks the alias needs nine of them -
which is more than the low-globals *reservation* covers: it is sized as one
L2 block (8 MB with 4 KiB pages, 32 MB with 16 KiB pages), so with 4 KiB
pages blocks 4..9 landed in kernel_map's first free hole and the first kmem
claim panicked in `pmap_ttne()` ("Attempt to demote L2 block", `0062`
extends the reservation to 32 MB). The VM must never hand out a VA that a
boot-time block mapping owns; that invariant is the thing to check first
when a `pmap_enter()` panics this way.

**Three more things did not fit in the 39-bit layout**, and each one
showed up as a panic that named the culprit:

| Symptom | Cause | Fix |
| --- | --- | --- |
| `kmem_range_init: vm_map_locate_space failing for claim kmem_ptr_range` | `ZONE_MAP_VA_SIZE` is 128 GiB on the macOS platform, more than the 112 GiB of kernel VA | patch `0057`: the embedded sizes (24 GiB) |
| `write_pte_fast: PTE write is unaligned` | `arm_init.c` picks 16 KiB software pages for any device with more than 1 GiB of RAM, while the hardware page is 4 KiB | patch `0058`: `PAGE_SHIFT_CONST = ARM_PGSHIFT` |
| `Undefined kernel instruction: instr=d51b42a2` (`msr dit, x2`) | the kernel is armv8.5 and saves DIT when it switches context; QEMU's `cortex-a76` is armv8.2 and does not implement it | not a kernel bug: `tools/qemu-ios.py` uses the `max` CPU for the mondrian |

**How these were found without burning a CI run each**: boot the kernel
in QEMU and read its own state.

```bash
# boot, keep the framebuffer, the serial log and the QEMU log
tools/qemu-ios.py payload out --kernel kernel.development.mondrian --board mondrian
tools/qemu-triage.py out kernel.development.mondrian     # first exception + symbol

# read any kernel variable (physical address of the guest)
tools/qemu-ios.py payload out --kernel kernel.development.mondrian --board mondrian \
    --hmp "xp/8gx 0x<pa>"          # pa = VA - link address + phys_base + 0x4000

# read the system registers
tools/qemu-ios.py payload out --gdb --kernel ... --board mondrian
lldb -o "gdb-remote 1234" -o "register read -a"
```

**Check:** the kernel passes `arm_init`, initialises the VM, IOKit, the
scheduler, the PRNG, libpthread and AMFI, and stops where it needs the
root device.


### 2. The generic half of the sweet series — done

Everything in `xnu/patches/` that does not talk to the hardware is ported
to `xnu/patches-mondrian/`: the RAM disk root (0021-0024), AMFI (0025,
0035, 0036), the HFS+ root (0026), BearSSL (0020, 0027, 0032, 0033), the
console and the crash log (0010, 0012, 0043-0047), the entitlement and
bindfs work (0035-0038), the HID services (0058), the iPhone identity
(0059), the SMP (0065, 0078) and the net trace (0080).

`tools/port-series.py` does the renaming (`SWEET` -> `MONDRIAN`,
`sweet_ufs.c` -> `mondrian_ufs.c`, the `sweetfb_*` boot arguments ->
`mondrianfb_*`, the `/sweet-ufs` device tree node -> `/mondrian-ufs`, the
`SweetPlatformExpert` -> `MondrianPlatformExpert`, the `IONameMatch`
`xiaomi,sweet` -> `xiaomi,mondrian`).

Two things needed attention beyond the renaming:

* **Page size.** The `__ARM_16K_PG__` define disappears, so XNU runs with
  `PAGE_SHIFT` 12. The physmap fix of 0011 is written in terms of
  `ARM_TT_TWIG_SIZE` and follows, but the *early* console and the boot
  arguments that assume 16 KiB granules have to be checked.
* **The kernel's L2 block mapping** is 2 MB instead of 32 MB, so
  `tools/mkpayload.py` rounds the kernel's virtual base down to 2 MB
  (it does, through `board.tt_l2_size`).

`tools/apply-series.py` checks the result against a real xnu tree:

```
git clone --depth 1 --branch xnu-8796.141.3 \
    https://github.com/apple-oss-distributions/xnu.git xnu8796
tools/apply-series.py xnu8796 --series xnu/patches-mondrian --machine MONDRIAN
```

### 3. The UFS 3.1 root device

This is the biggest piece of work. Sweet's driver
(`bsd/dev/sweet_ufs.c`, patch 0028) talks to a UFSHCI 2.1 host: a 8 dword
UTRD, a 32 bit PRDT, polled SCSI commands on LUN 0.

SM8475 has a UFS 3.1 host. The register names the driver uses
(`UTRLBA`, `UTRLDBR`, ...) still exist, but:

* the UTRD is 16 dwords and the PRDT entries are 64 bit;
* the host may be in MCQ mode, which sweet's driver does not implement;
* the UFS 3.1 PHY is on its own clock and power rail (RPMh), which the
  bootloader leaves running, but the reset handling differs.

The Linux driver for the same IP is `drivers/scsi/ufs/host/ufs-qcom.c` in
the CAF tree (MiCode/Xiaomi_Kernel_OpenSource, branch `mondrian-s-oss`); its
register offsets and the `ufs_mem` node are the reference for the XNU
version.

**Check:** `rd=ufsroot0` mounts the `userdata` partition and the kernel
prints the same "userdata on LUN 0" line as on sweet.

The driver is read-only (`mondrian_ufs_write()` returns `EROFS`) and the
disk commands it issues — TEST UNIT READY, NOP, QUERY, START STOP UNIT —
do not touch the medium, so nothing here can damage the table. That changes
only when writes are enabled to mount a read/write root; `tools/backup-gpt.sh`
records both copies of the GPT (fastboot's view of the partitions, and the
raw primary/backup headers through adb) before that step.

Sweet's persistent console log (`0047`: a 4 MiB ring at the end of
`userdata`, header `SWEETLOG`, read back from a recovery with
`tools/ios-log-pull.sh`) is not ported yet because it needs that write path.
It is the first thing to port once the partition reads, because from the
moment userland starts, a panic there is only visible through it — the phone
console cannot scroll and the USB stack is not up.

**Known debt in the GPT reader.** `ufs_find_partition()` bounds the entry
table with `nent * esz > BOUNCE_SIZE`, but the product is 32-bit: a corrupt
table with `nent` a multiple of 2^25 makes it wrap to a small number, the
check passes, the read asks for zero blocks and the loop then walks `nent`
entries past the bounce buffer — a fault that would look like a UFS failure.
Guard with `nent > BOUNCE_SIZE / esz` *before* multiplying, in the same patch
that enables writes (when a corrupted table stops being hypothetical).

### 4. The display

Sweet's panel is an LCD in DSC video mode: the bootloader leaves a
framebuffer at 0x9c000000 and the kernel copies the rendered image into it
(0046, 0056, 0079). Imported from the live device tree of mondrian:
`cont_splash_region` at **0xB8000000, 0x2B00000 (43 MiB)**, and the console
has been drawing into it since the first phone boot
(`initialize_screen: b=B8000000`), at 1440x3200, stride 5760.

That is the same situation as the sweet, and it is the important finding:
mondrian's panel is AMOLED behind a DSI D-PHY in command mode with DSC, but
the ABL has already brought the whole pipe up (DSI, DSC, MDP scanout) and
the display hardware keeps scanning the reserved buffer out of RAM on its
own. Nothing in XNU touches the DISP clocks or the DSI controller, so the
scanout survives the kernel: a photo taken minutes into a boot shows the
current text, not a frozen splash. A linear framebuffer therefore exists on
this phone too, which is what the userland framebuffer driver needs, and the
MDSS/DSI driver is **not** on the critical path for the lockscreen.

What has to be true for that to keep working:

* The buffer must never be handed out as free RAM. The boot arguments
  describe the whole window as memory, so `pmap_next_page()` is taught to
  step over the region (`0083`); the PE reads the extent from the ADT.
* The byte order and the stride have to be known before userland writes
  pixels. `0084` paints four bars (red, green, blue, white) in the two rows
  the console leaves free at the bottom of the screen: one photo then says
  whether the packing is XRGB or XBGR, whether alpha is honoured, and
  whether the width is the whole panel.
* The screen must not go idle. Idle power collapse is a feature of the
  display driver, which is not loaded here; the ABL does not enable it,
  so the scanout is expected to persist. If the panel ever stops (blank or
  frozen after a while), that is the signal to write the DSI driver.

`0085` is sweet's IOSurface + IOMobileFramebuffer pair ported to this
board: `AppleCLCD` matches `/arm-io/disp0` (`compatible = mondrian,display`,
already in the ADT from `mkadt.py`), publishes the panel memory as an
IOSurface, and presents by copying the enabled layers into it. Only the
geometry changed (1440x3200 at 526 ppi, not 1080x2400 at 395). It is
untested on hardware and lives on its own branch until the root mounts.

Sweet's two follow-ups on that file are **not** ported yet and have to be
rebased on `MondrianFramebuffer.cpp` when they are needed: `0056` (present
at most once every few vsyncs) and `0079` (`RequestPowerChange`: fade the
panel to black when backboardd asks for display off, which is what the
power button and auto-lock use).

**Check:** the iOS home screen appears on the phone.

**Fallback, only if the scanout dies:** an MDSS driver — the
`qcom,mdss_mdp@ae00000` node (0x0AE00000 + 0x84000, VBIF at 0x0AEB0000,
regDMA at 0x0AEAC000), the panel `qcom,mdss_dsi_m11a_42_02_0a_dsc_cmd`
(`msm_drm.dsi_display0` in the boot arguments), and the gamma/LUT and DSC
tables from the vendor tree. The DSI and DSI-PHY nodes are not in the live
DTB the ABL passes (it is trimmed), so their registers would have to come
from the `mondrian-s-oss` device tree. Weeks of work; it is not needed if
the splash keeps running.

### 5. The touch

Sweet drives a Goodix GT9896 over I²C on a GENI SE (0060, 0063) and gets the
touch rail from RPMh (0062). Mondrian's panel has a Goodix on **SPI**
(`xiaomi,m11a-spi`, `goodix_firmware_m11a`, IRQ on TLMM GPIO21, reset on
GPIO20, panel 1440x3200), on the QUPv3 SE4 at 0x990000 (SPI 3, interrupt
GIC SPI 605).

The protocol is a Goodix one, but the transport is not I²C: a QUPv3 SPI
transfer, with the "GENI FIFO packing" of 0063 to be reworked.

**Check:** touching the screen moves the pointer in Settings.

### 6. The buttons and the battery

The power and volume keys are on the PMIC: on sweet the PM6150 PON block and
SPMI SID 4, on mondrian the PM8008. The volume up key is a plain GPIO of the
PM8350 (`&pm8350_gpios 6`), so it can be read through the PMIC GPIO
controller instead of the PON block. The fuel gauge is a different part
altogether: sweet's `IOPMPowerSource` reports a static 100 % and charges
nothing; on mondrian the same stub is fine for a first bring-up.

### 7. USB

Sweet's USB stack (0072-0077, 0081) is a DWC3 driver for the SM7150
controller. SM8475 has a DWC3 as well, but with a different configuration
space and a USB3 PHY that needs its own clock and power sequencing. The
network path (the `sweet-usbnet.sh` script) is what made the bring-up
possible without a screen, so this is worth porting early.

## Getting the numbers off the device

The shim can dump the live device tree, which is where the memory map and
the peripheral addresses come from:

```
BOARD=mondrian shim/build.sh
fastboot boot shim/out/shim-boot.img
```

The screen shows lines like

```
FACT memory reg0 0x0 0x80000000
FACT memory reg1 0x100000000 0x7fc00000
FACT reg /soc/intc 0x17100000 0x10000 0x17180000 0x200000
FACT reg /soc/ufs_mem 0x1d84000 0x3000
```

Copy them into a file and let the tools read it:

```
python3 tools/mkadt.py mondrian.adt --board mondrian --highmem --facts facts.txt
```

`tools/boards.py` fills in the memory banks, the UFS host and the GIC from
such a dump (`parse_facts`, `apply_facts`). The dump is also the fastest way
to settle the **TODO** entries of the board table.

## Boot arguments

The board table carries the default kernel command line
(`boards.Board.cmdline`). For mondrian it is sweet's, with the framebuffer
arguments renamed:

```
debug=0xc serial=3 cpus=6 keepsyms=1 -enable_kprintf_spam -noprogress
rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1
wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1
wdt=-1 mondrianfb_noconsole=1 mondrianfb_hz=30
```

`cpus=6` starts the boot CPU (the X2) and the first five cores. On mondrian
that is the X2, the three A710s and two A510s; `cpus=8` is the full set.

## Dual boot (Android on slot a, iOS on slot b)

The goal: at power on the phone offers iOS and Android; the volume keys
navigate and the power key confirms. The ABL of Xiaomi is untouchable (see
the safety section), so the selector lives where this project already
controls the boot: the shim (slot b) and, when a choice has to leave a
trace the ABL would read, the kernel's own UFS driver.

| Phase | What it does | State |
| --- | --- | --- |
| v0 | the shim draws a band at the bottom of the framebuffer and counts 5 s down to iOS (`shim/menu.c`; the choice has no keys yet) | first on-device photo pending |
| v0.1 | the menu becomes a full-screen selector: page background, one card per choice with a generated one-bit logo (`shim/menu_logos.h`, made by `tools/gen-menu-logos.py`) and the countdown; still no keys | built (`7d65c89`), volatile boot done, photo pending |
| v1 | reboot from inside: the shim already has `PSCI_SYSTEM_RESET` + `PSHOLD 0x0c264000` and the restart reason at 0x146aa65c; in the kernel the reset has to be the WDT (a "MACH Reboot" hangs today) | planned; validate the reset first |
| v2 | switching the A/B slot: the kernel's UFS stack (end to end: GPT + `userdata`) writes the 4 KiB `misc` BCB of AOSP and resets; unproven with this ABL is whether it honors what `misc` says (the proverb test is `fastboot getvar current-slot`) | planned; design note: `shim/ufs.c` is read-only SCSI, a WRITE(10) fits in ~40 lines, so the shim may be able to do the whole switch alone |
| v3 | the keys: the power key is not a TLMM gpio, it comes out of the PMIC's PON block over SPMI; at least one volume key is on the PM8350 per `qcom/xiaomi-sm8475-common.dtsi`. Poll, no interrupts: the ABL does not configure anything for this | read the stock dtsi first |
| v4 | remember the last choice (boot args or a byte of the payload), timeouts | later |

`boot_a` stays untouched at all times: the Android installation keeps its
boot image where it was, and `fastboot boot` (Power+VolDown) is still the
rescue path of a boot that went wrong.

## References

* `MiCode/kernel_devicetree`, branch `mondrian-s-oss`
  * `qcom/cape.dtsi` — GICD/GICR, TLMM, SPMI, the CPU nodes
  * `qcom/cape-reserved-memory.dtsi` — the firmware carve-outs in DRAM
  * `qcom/mondrian-sm8475.dtsi` — the Goodix touch on QUPv3 SPI
  * `qcom/xiaomi-sm8475-common.dtsi` — the volume up key on the PM8350
  * `qcom/waipio-qupv3.dtsi` — the QUPv3 wrapper and the SE addresses
* `MiCode/Xiaomi_Kernel_OpenSource`, branch `mondrian-s-oss`
  * `build.config.msm.mondrian` — `PAGE_SIZE=4096`
* mainline Linux `qcom/sm8450.dtsi` — the UFS host at 0x1d84000, MDSS and
  the DPU, the GIC redistributor stride
* `apple-oss-distributions/xnu`, tag `xnu-8796.141.3` — the page table
  geometry (`osfmk/arm64/proc_reg.h`) and the page size selection
  (`osfmk/mach/arm/vm_param.h`)
