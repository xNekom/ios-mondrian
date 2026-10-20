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

The port must never turn a mistake into a brick. The rules:

| Operation | Risk | Rule |
| --- | --- | --- |
| `fastboot boot shim-boot.img` | none | temporary, nothing is written to any partition. A bad image just leaves the phone in fastboot. |
| `fastboot flash userdata …` | **erases the Android user data** (recoverable by reflashing Android) | only after the user says so. `tools/flash-root.sh` does this and nothing else. |
| `fastboot flash boot/init_boot/dtbo/vbmeta/abl/tz` | **hard brick** | never. The bootloader chain is not touched, in this fork or upstream. |

Two more rules, because the failure mode that is *not* a brick is still
bad: writing to a wrong address.

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

**The early boot of the kernel is where the remaining problem is.** With
4 KiB pages the kernel faults with a prefetch abort on the first
instruction of `arm_init` (a permission fault with the execute bit clear).
`tools/qemu-triage.py` says so from a QEMU run:

```
$ tools/qemu-triage.py /tmp/qemu-out kernel.development.mondrian
first exception:
   Taking exception 3 [Prefetch Abort] on CPU 0
   ESR 0x21 / 0x86000004 -> instruction abort, permission fault, level 1, execute never
   FAR 0xfffffe0007a6233c
   symbol _arm_init (+0x0)
```

The control experiment is the sweet kernel rebuilt with 4 KiB pages
(branch `exp/sweet-4k`): if it fails the same way, the problem is in XNU
and not in the port.

**Check:** the kernel reaches `arm_init` and the early console prints.


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

### 4. The display

Sweet's panel is an LCD in DSC video mode: the bootloader leaves a
framebuffer at 0x9c000000 and the kernel copies the rendered image into it
(0046, 0056, 0079). Mondrian's panel is an AMOLED behind a DSI D-PHY: the
image has to be sent to the DSI controller (MDSS 0x0ae00000, DPU 0x0ae01000)
as command mode packets, with the panel's own timing.

**TODO:** find out what the ABL leaves behind. On some Qualcomm devices the
bootloader draws the splash into a "sec boot screen" region; the address and
its geometry have to be read from the device. The shim prints the device
tree of the phone, which is where to look.

Until then, the early console (0010, 0012) is the only way to see the kernel.

**Check:** the iOS home screen appears on the phone.

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
