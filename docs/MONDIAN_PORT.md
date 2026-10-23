# Porting ios-sweet to the POCO F5 Pro (mondrian)

`sweet` is a Redmi Note 10 Pro: Snapdragon 732G (SM7150), ARMv8.2, 16 KiB
pages, an LCD in DSC video mode, a Goodix touch on I²C and a PM6150.
`mondrian` is a POCO F5 Pro (the global Redmi K60): Snapdragon 8+ Gen 1
(SM8475), ARMv9.0, 4 KiB pages, an AMOLED on DSI D-PHY, a Goodix touch on SPI
and a PM8008.

Same idea (stock iOS 16 userland on a patched XNU), different silicon. This
document is the work list: what is in place, what each remaining subsystem
needs, and where the numbers come from. The boot history and the traps are in
`NOTES.md`.

## The hardware delta

| | sweet (SM7150) | mondrian (SM8475) |
| --- | --- | --- |
| CPU | 2x Cortex-A76 + 6x Cortex-A55, ARMv8.2 | 1x Cortex-X2 + 3x Cortex-A710 + 4x Cortex-A510, ARMv9.0 |
| Page size | 16 KiB (`__ARM_16K_PG__`) | **4 KiB** (`PAGE_SIZE=4096` in `build.config.msm.mondrian`) |
| Page tables | L2 block = 32 MB | L2 block = 2 MB (`ARM_4K_TT_L2_SIZE`) |
| Pointer auth | none | none (compile plain arm64, like sweet) |
| GICD | 0x17a00000 | **0x17100000** |
| GICR | 0x17a60000, 2 RDs, stride 0x20000 | **0x17180000, 8 RDs, stride 0x40000** |
| Timer INTID | 19 (Qualcomm PPI numbering) | 19 (same numbering) |
| UFS host | ufshc@1d84000, UFSHCI 2.1 | ufshc@1d84000, **UFS 3.1** |
| Touch | Goodix GT9896 on I²C (GENI SE) | **Goodix on QUPv3 SPI** (`xiaomi,m11a-spi`, SE4 @ 0x990000) |
| Buttons | PM6150 PON / SPMI | **PM8008** (PMR735A + PM8350B); volume up on PM8350 GPIO6 |
| Display | 1080x2400 LCD, DSC video mode, splash at 0x9c000000 | **1440x3200 AMOLED, DSI D-PHY**; splash at 0xb8000000 |
| Memory | 0x80000000+2 GiB, 0x100000000+0xfcc00000 | `0x80000000+0x6a000000`, `0xf4600000+0xba00000` |
| PMIC rails | PM6150 LDO11 (touch), fuel gauge | PM8008 rails, fuel gauge (not needed yet) |

## What is already in this fork

| Piece | State |
| --- | --- |
| `tools/boards.py` | board table (MMIO, memory, CPU topology, page size, boot args) for both boards |
| `tools/mkadt.py --board` | builds the Apple Device Tree for either board, refuses values still marked provisional |
| `tools/mkpayload.py --board` | packs kernel + ADT + boot arguments with the board's payload magic and L2 block size |
| `shim/board.h`, `shim/build.sh BOARD=` | the shim for either board; `fdt.c` parses the live device tree so the table can be filled from the device |
| `xnu/patches-mondrian/0001`–`0002` | the XNU machine config for SM8475 and `config/MASTER.arm64.mondrian` |
| `xnu/patches-mondrian/0003`–`0055` | the generic half of the sweet series, ported (RAM disk root, AMFI, HFS+, BearSSL, console, crash log, HID, SMP, iPhone identity) |
| `xnu/patches-mondrian/0056`–`0062` | the 4 KiB page work (commpage, zone map VA, software page size, bootstrap VA, no physical timer, framebuffer alias) and the first UFS root device (`0059`) |
| `xnu/patches-mondrian/0063`–`0082`, `0086` | the boot diagnostics and the UFS 3.1 root device |
| `xnu/patches-mondrian/0083`–`0084`, `0087`, `0088` | panel memory reservation, colour-bar self-test, GIC remap after the VM, VFS_ROOT errno |
| `tools/apply-series.py`, `tools/check-patches.sh` | apply a series to a fresh xnu tree in seconds and report what does not apply |
| `tools/port-series.py` | ports a patch of the sweet series, renaming the board identifiers, and lists the hardware patches it skips |

`0085` (the framebuffer driver) lives on branch `display` and is merged only
once the root mounts.

## Safety: what can and cannot brick the phone

The boot chain is Qualcomm firmware below the Android images:
`xbl` → `xbl_config` → `abl` → `tz`/`hyp`/`uefisecapp`/modem. An image in that
chain cannot be repaired by the OS or by fastboot — on this device the only
way back is EDL with an authorized Xiaomi account — so it stays out of bounds
permanently. Everything this port writes lives above it, where the stock
fastboot ROM can restore any image.

### Partition policy

Written — the allow-list; everything else is off:

| Partition | Role | Extra rule |
| --- | --- | --- |
| `boot_b` | the shim slot | the routine target of the port |
| `boot_a` | stock Android, the escape hatch | the deploy tooling refuses it (`BOOT_A=1` is the deliberate override); a verified backup precedes any write |
| `vendor_boot` | the shim reads its live device tree from it | dump verified by SHA256 first |
| `misc` | the A/B boot-control block; dual boot writes it from the kernel | wrong content only selects the wrong slot; `fastboot --set-active` fixes it without flashing |
| `init_boot`, `recovery` | untouched so far (this device has no `init_boot`) | the same safeguards whenever a write is needed |
| `userdata` | the iOS root | erasing Android user data here is acceptable and recoverable; `tools/flash-root.sh` writes it and asks first |

Repeated volatile `fastboot boot` runs — including failures and panics — touch
no partition, and a slot switch only marks state.

Never written — an irreversible brick: `xbl`, `xbl_config`, `abl`, `tz`,
`hyp`, `uefi*`/`uefisecapp`, `modem*`, `persist`, and every other low-level
image the stock ROM ships. Also read-only because nothing needs them and a bad
copy can break verified boot or device-tree delivery: `vbmeta`, `dtbo`.

### A definitive write, in graded steps

1. **Volatile proof first.** `fastboot boot` the same image. A bad image
   leaves the phone in fastboot and nothing worse.
2. **Name the target.** `fastboot getvar current-slot`; the write pins to that
   `boot_<slot>`, so `boot_a` is never hit by accident.
3. **Verified originals.** Dump the target, pull it to `backup/`, record it in
   `SHA256SUMS` and check the sum before writing. The copy on the phone dies
   with the next `userdata` wipe; the one on the workstation is the durable
   one.
4. **Write, read back, reboot, confirm the slot** the next boot came from.
5. **Keep the disaster baseline.** The complete stock fastboot ROM of this
   exact model restores every allow-list partition; keep it on disk before the
   first definitive write.

Two rules cover the other failure mode, writing to the wrong place:

- **The shim takes its addresses from the device tree the bootloader
  passed**: the framebuffer from the splash region, the UFS host from the
  `qcom,ufshc` node. The board table carries a documented fallback, never a
  guess.
- **No image is built from guessed numbers.** `tools/boards.py` marks
  unmeasured fields (`Board.provisional`) and `mkadt.py` / `mkpayload.py`
  refuse such a board; `--allow-provisional` is the deliberate way past it.
  Values are cleared by feeding a shim facts dump (`--facts facts.txt`).

## The window of RAM

The kernel gets `phys_base = 0xb0000000`, `mem_size = 0x46000000`. The rules
behind those two numbers are in `NOTES.md` ("The window of RAM"): it must
contain the splash framebuffer, start above the firmware's own memory (the
hypervisor resets the phone when overwritten) and end in memory that exists
(0xea000000..0xf4600000 is a hole, and XNU takes its first heap pages from the
end of the window). The floor is 0x3a000000, and the physmap slide comes from
`/chosen/random-seed`, so the seed is pinned in `tools/boards.py`.

| what | value |
| --- | --- |
| `/memory` | `0x80000000+0x6a000000`, `0xf4600000+0xba00000`, four above 32 GB |
| usable RAM per the bootloader | 1.85 GB (`ddr_size` says 12) |
| `/reserved-memory` | 38 carve-outs: hypervisor 0x80000000+0x600000, AOP, SMEM, modem 0x8bc00000+0x13200000, splash 0xb8000000+0x2b00000, tags, QTEe |
| framebuffer | 0xb8000000, 1440x3200, stride 5760 |
| GIC | GICD 0x17100000+0x10000, GICR 0x17180000+0x200000, stride 0x40000 |
| virtual timer | INTID 19 |
| UFS host | 0x1d84000 (`ro.boot.bootdevice` = `1d84000.ufshc`) |

The board table and the shim hold the window; the shim checks the live device
tree agrees that it is inside a memory region and prints that on the screen.

## The 4 KiB work

The board runs 4 KiB pages, which is the part of the port that is not a
rename: page table geometry, the commpage check, the zone map, the bootstrap VA
window, the software page size and the framebuffer alias all assume 16 KiB
somewhere. Each fix and its symptom are tabulated in `NOTES.md`; the invariant
worth remembering is that the VM must never hand out a VA owned by a boot-time
block mapping (`pmap_enter()` then panics in `pmap_ttne()`).

ARMv9.0 is binary compatible with the ARMv8.5 baseline, so the kernel builds
for `armv8.5-a` with plain `arm64` (the X2/A710/A510 have no pointer
authentication) and uses 39-bit virtual addresses, which ARMv9 still allows.

## Remaining work

### 1. The iOS root (current blocker)

Reads work end to end (UFS → GPT → `userdata` → HFS). What is missing is the
root vnode: `hfs: mounted iOSRoot` is followed by
`bsd_init: cannot find root vnode`. `0088` prints the errno so the next photo
names it; the current `userdata` holds a 64 MB test image, and the plain H+
twin versus the HFSX original separates "catalog cannot answer" from "read
fails".

The persistent console log (sweet `0047`: a 4 MiB ring at the end of
`userdata`) is not ported because it needs the write path. Port it right after
writes land: from the moment userland starts, a panic there is only visible
through it — the console cannot scroll and the USB stack is not up.

### 2. The UFS root device

The driver is read-only (`mondrian_ufs_write()` returns `EROFS`) and its
commands do not touch the medium, so nothing here can damage the table. The
bring-up sequence, the register state and the GPT-reader overflow debt are in
`NOTES.md`. Writes are needed for the persistent log and for a writable root;
`tools/backup-gpt.sh` records both copies of the GPT before that step.

### 3. The display

The ABL keeps the panel scanning a linear framebuffer, so the MDSS/DSI driver
is not on the critical path. Outstanding: `0083` (panel memory off the free
list), `0084` (colour bar self-test: XRGB vs XBGR, alpha, width) and `0085`
(sweet's IOSurface + IOMobileFramebuffer pair, branch `display`), plus the
rebases of sweet `0056`/`0079` (present rate, `RequestPowerChange`).
If the scanout ever stops, the fallback is a real MDSS driver: the
`qcom,mdss_mdp@ae00000` node, the panel
`qcom,mdss_dsi_m11a_42_02_0a_dsc_cmd`, and the gamma/DSC tables from the
vendor tree.

### 4. The touch

Sweet drives a Goodix GT9896 over GENI I²C and takes its rail from RPMh.
Mondrian has a Goodix on **SPI** (`xiaomi,m11a-spi`, IRQ TLMM GPIO21, reset
GPIO20) on QUPv3 SE4 at 0x990000 (GIC SPI 605). The protocol is Goodix; the
transport is a QUPv3 SPI transfer, with sweet's GENI FIFO packing reworked.

### 5. The buttons, the battery and the menu

The shim already reads the keys over SPMI (see `NOTES.md` for the arbiter v7
layout and the key map) and drives the boot menu. What remains is the kernel
side: a HID button service like sweet `0060`, and the dual-boot phases —
kernel reset, then the A/B slot switch through `misc`. The battery can keep
sweet's static `IOPMPowerSource` stub for the first bring-up.

### 6. USB

Sweet's stack (0072–0077, 0081) is a DWC3 driver for SM7150. SM8475 has DWC3
as well, with a different configuration space and a USB3 PHY that needs its
own clock and power sequencing. The network path is what made sweet's bring-up
possible without a screen, so it is worth porting early — but it is not needed
while the console photo works.

## Getting the numbers off the device

```
BOARD=mondrian shim/build.sh
fastboot boot shim/out/shim-boot.img
```

The screen shows lines like

```
FACT memory reg0 0x0 0x80000000
FACT reg /soc/intc 0x17100000 0x10000 0x17180000 0x200000
FACT reg /soc/ufs_mem 0x1d84000 0x3000
```

Copy them into a file and let the tools read it:

```
python3 tools/mkadt.py mondrian.adt --board mondrian --facts facts.txt
```

`--altmem` selects the upper DDR bank instead of the window in the board table
(sweet uses it; mondrian boots from the low window).

`tools/boards.py` fills the memory banks, the UFS host and the GIC from such a
dump (`parse_facts`, `apply_facts`).

## Boot arguments

The board table carries the default command line (`boards.Board.cmdline`): the
sweet's, with the framebuffer arguments renamed.

```
debug=0xc serial=3 cpus=6 keepsyms=1 -enable_kprintf_spam -noprogress
rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1
wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1
wdt=-1 mondrianfb_noconsole=1 mondrianfb_hz=30
```

What the less obvious ones do:

| Boot-arg | Effect |
| --- | --- |
| `rd=ufsroot0 ufsrw=1 rootrw=1` | root on the `userdata` partition, writable |
| `cpus=6` | start the X2 and the first five cores; `cpus=8` is the full set, `cpus=1` the safe fallback |
| `launchd_unsecure_cache=1` | launchd accepts its job cache without AMFI |
| `wdt=-1 wdt_test=no_user_checkin` | no hardware watchdog, no userspace watchdog check-in |
| `mondrianfb_noconsole=1` | stop drawing kernel text over the GUI (panics are still drawn) |
| `mondrianfb_hz=30` | refresh rate of the CPU copy into the panel |
| `-noprogress` | keep the graphical boot indicator out of the console text |

## References

Sources for the numbers above:

* `MiCode/kernel_devicetree`, branch `mondrian-s-oss`
  * `qcom/cape.dtsi` — GICD/GICR, TLMM, SPMI, the CPU nodes
  * `qcom/cape-reserved-memory.dtsi` — the firmware carve-outs in DRAM
  * `qcom/mondrian-sm8475.dtsi` — the Goodix touch on QUPv3 SPI
  * `qcom/xiaomi-sm8475-common.dtsi` — the volume-up key on the PM8350
  * `qcom/waipio-qupv3.dtsi` — the QUPv3 wrapper and the SE addresses
* `MiCode/Xiaomi_Kernel_OpenSource`, branch `mondrian-s-oss`
  * `build.config.msm.mondrian` — `PAGE_SIZE=4096`
* mainline Linux `qcom/sm8450.dtsi` — the UFS host, MDSS/DPU, GIC strides
* `apple-oss-distributions/xnu`, tag `xnu-8796.141.3` — page table geometry
  (`osfmk/arm64/proc_reg.h`) and page size selection
  (`osfmk/mach/arm/vm_param.h`)

Other ports worth reading are listed in `NOTES.md`.
