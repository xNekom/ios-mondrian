# Porting ios-sweet to the POCO F5 Pro (mondrian)

`sweet` is a Redmi Note 10 Pro: Snapdragon 732G (SM7150), ARMv8.2, 16 KiB
pages, an LCD in DSC video mode, a Goodix touch on I²C and a PM6150.
`mondrian` is a POCO F5 Pro (the global Redmi K60): Snapdragon 8+ Gen 1
(SM8475), ARMv9.0, an AMOLED on DSI D-PHY, a Goodix touch on SPI and a
PM8008.

Same idea (stock iOS 16 userland on a patched XNU), different silicon. This
document is the work list: what is in place, what each remaining subsystem
needs, and where the numbers come from. The boot history and the traps are in
`NOTES.md`.

## The hardware delta

| | sweet (SM7150) | mondrian (SM8475) |
| --- | --- | --- |
| CPU | 2x Cortex-A76 + 6x Cortex-A55, ARMv8.2 | 1x Cortex-X2 + 3x Cortex-A710 + 4x Cortex-A510, ARMv9.0 |
| Page size | 16 KiB (`__ARM_16K_PG__`) | 16 KiB: `TGran16=1` measured, iOS userland needs it |
| Page tables | L2 block = 32 MB | L2 block = 2 MB (`ARM_4K_TT_L2_SIZE`) |
| Pointer auth | none | none (compile plain arm64, like sweet) |
| GICD | 0x17a00000 | **0x17100000** |
| GICR | 0x17a60000, 2 RDs, stride 0x20000 | **0x17180000, 8 RDs, stride 0x40000** |
| Timer INTID | 19 (Qualcomm PPI numbering) | **27 (GIC INTID; DT PPI 11)** |
| UFS host | ufshc@1d84000, UFSHCI 2.1 | ufshc@1d84000, **UFS 3.1** |
| Touch | Goodix GT9896 on I²C (GENI SE) | **Goodix on QUPv3 SPI** (`xiaomi,m11a-spi`, SE4 @ 0x990000) |
| Buttons | PM6150 PON / SPMI | **PM8008** (PMR735A + PM8350B); volume up on PM8350 GPIO6 |
| Display | 1080x2400 LCD, DSC video mode, splash at 0x9c000000 | **1440x3200 AMOLED, DSI D-PHY, command mode** (one `CTL_START` a frame); splash at 0xb8000000 |
| Memory | 0x80000000+2 GiB, 0x100000000+0xfcc00000 | `0x80000000+0x6a000000`, `0xf4600000+0xba00000` |
| PMIC rails | PM6150 LDO11 (touch), fuel gauge | PM8008 rails, VADC fuel gauge (`0304`) |

## What is already in this fork

| Piece | State |
| --- | --- |
| `tools/boards.py` | board table (MMIO, memory, CPU topology, page size, boot args) for both boards |
| `tools/mkadt.py --board` | builds the Apple Device Tree for either board, refuses values still marked provisional |
| `tools/mkpayload.py --board` | packs kernel + ADT + boot arguments with the board's payload magic and L2 block size |
| `shim/board.h`, `shim/build.sh BOARD=` | the shim for either board; `fdt.c` parses the live device tree so the table can be filled from the device |
| `xnu/patches-mondrian/0001`–`0002` | the XNU machine config for SM8475 and `config/MASTER.arm64.mondrian` |
| `xnu/patches-mondrian/0003`–`0055` | the generic half of the sweet series, ported (RAM disk root, AMFI, HFS+, BearSSL, console, crash log, HID, SMP, iPhone identity) |
| `xnu/patches-mondrian/0056`–`0062` | page-size work (commpage, zone map VA, bootstrap VA, no physical timer, framebuffer alias) and the first UFS root device (`0059`); `0058` is gone with the 4 KiB software page size |
| `xnu/patches-mondrian/0063`–`0082`, `0086` | the boot diagnostics and the UFS 3.1 root device |
| `xnu/patches-mondrian/0083`–`0085`, `0087`–`0088` | panel memory reservation, framebuffer presentation, GIC remap after the VM, VFS_ROOT errno |
| `tools/apply-series.py`, `tools/check-patches.sh` | apply a series to a fresh xnu tree in seconds and report what does not apply |
| `tools/port-series.py` | ports a patch of the sweet series, renaming the board identifiers, and lists the hardware patches it skips |

`0085` (the framebuffer presentation driver) is in this series. `MondrianFramebuffer`
presents userland IOSurface swaps and kicks the command-mode interface, so the
lock screen and the home screen render on-device. UI probe `0106` injects a
diagnostic dylib into the UI daemons selected by `mondrian_ui_hook` (`0112`);
dyld needs the `AMFI` answer to `__mac_syscall` 0x5a (`0108`) or drops `DYLD_INSERT_LIBRARIES`. **A stale copy in
`/private/var/vm` is what kept the glass black; check which copy the ring says a
process loaded (`docs/MONDIAN_GPU.md`).** Build with the script named there.
`/product` needs `research/ipsw-x/d22ap.adt`; `disp0` `canvas-width`/
`canvas-height` must be 4-byte data (`u32` ADT, `OSData` driver), because
`getEDTProperty` reads them with `getBytes:range:` and an OSNumber or
OSString aborts backboardd. `0110`/`0111` expose and correct the virtual timer
mask; `0173` arms `CNTV_TVAL` before clearing IMASK for the clean shim.

### Exporting the full console ring

The raw area is a 4 KiB header plus a 4 MiB ring at the end of `userdata`.
Root ADB in recovery reads its final 1,025 blocks; `fastboot fetch` is absent.
Before reading, verify `userdata` is absent from `/proc/mounts` so recovery
cannot write or repair it:

```sh
bytes=$(adb shell blockdev --getsize64 /dev/block/by-name/userdata | tr -d '\r')
skip=$((bytes / 4096 - 1025))
adb shell "dd if=/dev/block/by-name/userdata of=/tmp/mondrian-log.raw bs=4096 skip=$skip count=1025"
adb pull /tmp/mondrian-log.raw mondrian-log.raw
tools/decode-mondrian-log.py mondrian-log.raw > mondrian-console.log
```

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

On 2026-10-28 `boot_b` held Lineage userdebug and the iOS image ran from
`fastboot boot`; the temporary Android split and its exact restore are in
`docs/DUAL_BOOT.md`.

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
3. **Verified originals.** For `boot_<slot>` and `vendor_boot`, dump the
   target, pull it to `backup/`, record it in `SHA256SUMS` and check the sum
   before writing. `userdata` is exempt on this test unit: it is erased and
   rewritten freely, and a reachable fastboot is the recovery path.
4. **Write, read back, reboot, confirm the slot** the next boot came from.
5. **Keep the disaster baseline.** The complete stock fastboot ROM of this
   exact model restores every allow-list partition; keep it on disk when
   convenient. The hard requirement is that fastboot stays reachable.

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

The kernel gets `phys_base = 0x840000000`, `mem_size = 0x240000000`: the
clean 9 GiB run of the live tree (its 3 GiB and 6 GiB `/memory` regions are
adjacent, with no reservation inside). The phone's 12 GiB are six regions
whose sum is 11.8 GiB; the rest is the low 1.66 GiB with the firmware
carve-outs, 885 MiB behind a 139 MiB hole and 30 MiB loose, so one contiguous
window cannot hold them all. The rules behind the window and the measured map
are in `NOTES.md` ("The window of RAM" and "Measured hardware facts").

The splash framebuffer is outside this window; the early console paints it
through the explicit kernel VA alias `arm_vm_init` installs (`0295`).

**Measured 2026-11-09**: iOS 16 boots to SpringBoard on the 9 GiB window, 208
processes and 5.2 GiB free. The 864 MiB window had the page queues full (616
MiB) and the compressor at another 221-251 MiB. The high-window boot is
slower: the shim wipes 9 GiB before the jump and iOS runs `fsck`/`mount_hfs`
on the root after an unclean reset.

**A plain `fastboot boot` boots it.** ABL's `/chosen/bootargs` (its Android
line) used to fill the 1024-byte command line and push `rd=ufsroot0` out; the
shim now reserves the payload's room first. `fastboot boot --cmdline "..."`
still overrides: XNU keeps the first occurrence of each key.

## Page size

The port started on 4 KiB pages because the stock kernel is built with
`PAGE_SIZE=4096`, and that cost a handful of panics (the table in `NOTES.md`
has them). It was the wrong default: iOS userland, its dyld shared cache and
the code signatures on it are built for 16 KiB, and the SoC implements the
granule (`ID_AA64MMFR0_EL1.TGran16 = 1`, measured 2026-10-23). The shim, the
payload and the kernel now all run 16 KiB, which removes those workarounds
and lets launchd register the shared cache.

ARMv9.0 is binary compatible with the ARMv8.5 baseline, so the kernel builds
for `armv8.5-a` with plain `arm64` (the X2/A710/A510 have no pointer
authentication).

## Remaining work

### 1. The iOS root

Reads and writes work end to end (UFS → GPT → `userdata` → HFS). With the iOS
16 root built by `tools/mkiosroot.sh`, prepared by `tools/ios-root-tweaks.py`
and flashed with `tools/flash-root.sh`, the lock screen comes up; a rebuilt
`mondrian-ui-hook.dylib` goes into the image with `tools/install-ui-hook.sh`.
The flattened HFS root is not a stock layout: launchd expects a Data volume and
`/private/preboot/<uuid>/` (`.roots-installed` and the firmware tree); the
non-journaled volume logs 10,000-13,000 `hfs_mark_inconsistent` lines once
damaged (none after a fresh restore), yet held 60 fps in a drag (`NOTES.md`).

The persistent console log is `0096`; `0174` arms its writer at the end of the
UFS probe, before the root mount, so a failed mount still flushes its error. Read
a prior boot over USB with `tools/usb-ring.py prev` (`0329`), or on the panel
with a dump kernel (`mondriandump=1`).

### 2. The UFS root device

The driver supports WRITE(10), read-modify-write and SYNCHRONIZE CACHE through
`0090`; `tools/backup-gpt.sh` records both GPT copies. The bring-up sequence,
register state and remaining GPT-reader overflow debt are in `NOTES.md`.

### 3. The display

The panel is command mode, not a scanout the ABL keeps running: it needs one
`CTL_START` per frame, which `MondrianFramebuffer` issues (`NOTES.md`,
"Display"). `0083` reserves the panel memory and `0085` presents IOSurface
swaps, so the lock screen and the home screen draw. `0084`'s colour bars were a
one-off packing test, off since `0208`; `0210` paints the kernel log and clears
the boot splash. Three things had to line up: CoreAnimation needs
`TimingElements`/`ColorElements` and an `IOAcceleratorES` service (`0114`); the
panel is written through the console alias, which is only stopped with
`disableConsoleOutput` (`0115`, an `IOMemoryDescriptor` there panics
`pmap_remove_pv`); and the dylib forces activation past MobileActivation.

Open: the UI renders at 1440x3200 (480x1066 pt, scale 3); the canvas scaler
(`0268`) is off and `docs/UI_PERFORMANCE.md` has the smoothness numbers.
`0302`/`0303` blank the panel on the power key and on idle sleep, and `0342`
switches it off with DCS `0x28` instead of painting the framebuffer black: iOS
stops presenting when it sleeps, so a key or a touch un-blanks and the tick
sends `0x29` -- a wake cannot wait for a frame. The fallback timer
(`mondrianfb_blank`) is 30 in the board cmdline. The hook's holds are off
(`mondriankeepawake=0`); iOS's timer never arms -- `SBLockScreenAutoLockTime` was
missing and the hook writes it, and `SBLockScreenManager` has no
`_idleTimerPolicyAggregator`. `0305` sets the brightness, `0304` the battery.
The GPU's pixels never reach memory, so the UI is rasterized on the CPU in
`backboardd` and a GL flush costs 10-12 ms on some frames (`docs/MONDIAN_GPU.md`);
sweet's `0056` and `0079` (`RequestPowerChange`) still need a rebase.

### 4. The touch

Sweet drives a Goodix GT9896 over GENI I²C. Mondrian's Goodix on SPI is up
(`0153`): TLMM, the GCC SE clocks, the GENI SPI transport and the firmware load
work. The part reports at about 350/s; the report thread is ticked from the
vsync and coalesces each drain into one HID event per finger per display tick
(`0288`), with repeats counted. The home and app-switcher gestures work
(`0300`): a contact that starts within ~3 mm of an edge carries
`kIOHIDDigitizerEventFromEdgeTip`, UIKit's touch edge type; a tap inside one
tick still loses its down event (`docs/MONDIAN_TOUCH.md`).

### 5. The buttons, the battery and the menu

The shim reads the keys over SPMI (arbiter v7 layout in `NOTES.md`) and
drives the menu; `0301` adds the kernel half (`bsd/dev/mondrian_spmi.c`): a
thread polls the PMK8350 PON and PM8350 GPIO6 and publishes both edges through
`MondrianHIDButtons`. `0304` publishes the pack level as an `IOPMPowerSource`
from its own thread, and `0305` sends the panel brightness (`bl LEVEL` over
USB) as a DCS long write. Nothing charges the phone, because the SMB5 is
behind the ADSP; dual-boot and heat remain (`docs/MONDIAN_POWER.md`).

### 6. USB

Done. The DWC3 gadget (`bsd/dev/mondrian_usb.c`, `usb=2`) enumerates as an ECM
Ethernet device at 192.168.7.2; udp/5141 drives the debug loop from
`tools/usb-ring.py` (see `README.md`). `0335` carries a read-only disk over the
GPT `userdata` partition but keeps it out of the descriptor: the core takes
`DEPCFG` on 0x02/0x03/0x83 with status 0 and never completes a packet, even
with the per-OUT-endpoint RX FIFO (`GRXFIFOSIZ`) sized. `usb=1` probes.

## Getting the numbers off the device

Boot the mutable shim (`BOARD=mondrian shim/build.sh`, `fastboot boot
shim/out/shim-boot.img`); the panel prints `FACT` lines for the memory regions
and the GIC/UFS nodes. Pass them to `mkadt.py --facts`; `tools/boards.py`
fills the banks, the UFS host and the GIC from the same dump (`parse_facts`).

## Boot arguments

The board table carries the default line (`tools/boards.py`); the less obvious
ones:

| Boot-arg | Effect |
| --- | --- |
| `rd=ufsroot0 ufsrw=1 rootrw=1` | root on the `userdata` partition, writable |
| `cpus=8` | every core the tree has, which is seven: the X2, the three A710s and three of the A510s. The A510 at Aff1 0 runs the shim and is parked, left out of the device tree (PSCI `CPU_OFF` does not take it down on this TZ). `cpus=1` is the safe fallback |
| `launchd_unsecure_cache=1` | launchd accepts its job cache without AMFI |
| `wdt=-1 wdt_test=no_user_checkin` | no hardware watchdog, no userspace watchdog check-in |
| `mondrianfb_noconsole=1` `mondrianfb_hz=60` | stop drawing kernel text over the GUI (panics are still drawn); the vsync rate the display presents at, on a panel whose own rate is 120 Hz |
| `glblob=1` | write the kernel's embedded GL, injector and UI-hook dylibs into `/private/var/vm` at mount; `kern_exec` prefers them, so a userland change needs one kernel build, not a userdata flash |
| `mondrianunlock=1` | the hook unlocks the lock screen and re-requests it every minute |
| `mondriankeepawake=0` | the hook stops holding `UIApplication`'s idle timer down (it does that every two seconds on purpose: the first time iOS blanked the display by itself the frames never came back). One boot with it off is how the idle path gets watched |
| `battfix=mv:pct,...` | replace `0304`'s built-in voltage table with measured points, up to four, any order (sorted by voltage). The vendor tree carries no mondrian profile, so the Android `capacity` against `voltage_now` pairs are the anchors: 3.80 V read 36 % there where the built-in table said 58 |
| `mondriankill=none` | refuse the exec of the jobs that abort in their own code on this port (calendar, speech, `watchdogd`, `bluetoothd`, `fairplayd.H2`, `aggregated`); `0316`, replaceable at run time with `execdeny` -- not `kill`, which takes a pid. `quiet` is the built-in list. A denied exec must still create a `signature_failure_reason` (`0328`): without one the assert in `kern_exec.c` fires and the half-initialised image dies inside the shared cache -- which cost the bench 400 of its 500 execs. Measured with the UI up, one-minute windows: off 1 crash/min, the three voice daemons 12, `quiet` 55, exec count flat at 28-30/min. A refusal is a SIGKILL the crash reporter counts, so the list is a loss once the UI runs; it stays as a switch |
| `-noprogress` | keep the graphical boot indicator out of the console text |
| length | 607 bytes at most. The kernel field is 1024, but iOS userland asks for `kern.bootargs` with a 608-byte buffer and the handler copies the whole string, so one byte over is `ENOMEM` for every reader; `watchdogd` reads it on each launch and aborts, and launchd answers with a respawn loop (~28 aborts in ten minutes, measured). `tools/mkpayload.py` refuses to build past it |

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

Other ports worth reading are listed in `NOTES.md`; the WiFi/Bluetooth
hardware and what iOS expects are in `docs/MONDIAN_WIRELESS.md`.
