# ios-mondrian

**Apple's iOS 16 running on a POCO F5 Pro.**

Fork of [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet), which
ports Apple's open-source XNU kernel (xnu-8796, the iOS 16 generation) to the
Xiaomi Redmi Note 10 Pro (`sweet`, SM7150) and runs the unmodified iOS 16.7.16
userland of the iPhone X on top of it: launchd, the system daemons,
backboardd, SpringBoard and the stock apps.

This fork's target is the **POCO F5 Pro / Redmi K60** (`mondrian`, Qualcomm
SM8475 / Snapdragon 8+ Gen 1). Same idea, different silicon: ARMv9.0 with
4 KiB pages, a UFS 3.1 host, an AMOLED on DSI D-PHY, a Goodix touch on SPI and
a PM8008.

> Experimental bring-up, not a usable phone OS. Many pieces are missing or
> stubbed and Apple's security model is mostly off. The iOS root lives in the
> `userdata` partition, so **installing it erases Android's user data**.

> [!IMPORTANT]
> **Not affiliated with Apple.** This is an independent educational and
> research effort, not endorsed by or developed with Apple Inc. Apple, iPhone,
> iOS, iPadOS, macOS and XNU are trademarks of Apple Inc. No Apple firmware,
> IPSW, filesystem image or other copyrighted Apple material is distributed
> here: you download and prepare those yourself. Only Apple's open-source
> releases (xnu, IOHIDFamily, libpthread, hfs) are used as source, under their
> own licences. Third-party components keep their own licences.

## Status

| | sweet (upstream) | mondrian (this fork) |
| --- | --- | --- |
| XNU machine config, kernel boots | done | **done** |
| Generic series (mockfs, AMFI, HFS, console, HID, SMP) | done | **done** |
| UFS root device | done (UFSHCI 2.1) | **reads** (UFS 3.1); writes pending |
| iOS root mount | done | blocked on `VFS_ROOT` |
| Display | done (LCD, DSC) | splash scanout works; userland driver on branch `display` |
| Touch | done (Goodix on I²C) | to write (Goodix on SPI) |
| Keys and battery | done (PM6150) | keys work in the shim; kernel side to write |
| Boot menu / dual boot | n/a | menu with keys works; slot switch pending |
| iOS userland | boots to the home screen | not yet |

On `sweet`, the reference implementation, the stock bootloader boots our shim
volatile, XNU mounts a journaled HFS+ iOS root from `userdata` read/write, and
the iPhone X userland reaches the home screen (CPU rendering, no GPU, no
Wi-Fi/cellular/audio/camera/SEP, navigation gestures still broken). That is the
target for this port: the patch series, the boot arguments and the root-image
tooling are shared, see `xnu/README.md`.

The port plan, the hardware delta, the safety rules and the work list are in
[`docs/MONDIAN_PORT.md`](docs/MONDIAN_PORT.md); the port state and the facts
that were expensive to learn are in [`NOTES.md`](NOTES.md).

## How it boots

```
ABL (stock Xiaomi bootloader, unlocked)
  -> fastboot boot shim-boot.img            (or the image in boot_b)
     -> shim: own MMU setup, reads the live FDT, unpacks the LZ4 payload
        -> XNU Mach-O + generated Apple Device Tree (ADT) + boot-args
           -> XNU -> UFS driver -> HFS+ root in the userdata partition
              -> dyld + shared cache -> launchd -> daemons -> backboardd + SpringBoard
```

There is no serial port (the debug UART is wired as SPI on these boards). The
kernel draws its console into the framebuffer the bootloader leaves — 1440x3200
at `0xb8000000` on mondrian, 1080x2400 at `0x9c000000` on sweet — and keeps the
whole log in a 4 MiB ring at the end of `userdata` (`0096`), because a screen
only ever shows the last page of a boot.

## Boards

The shim, the device tree builder and the payload packer take a `--board`
argument. The numbers live in [`tools/boards.py`](tools/boards.py) and, for the
shim, in `shim/board.h` (change both together).

| board | phone | SoC | page size | kernel series |
| --- | --- | --- | --- | --- |
| `sweet` | Redmi Note 10 Pro | SM7150 / Snapdragon 732G | 16 KiB | `xnu/patches/` |
| `mondrian` | POCO F5 Pro / Redmi K60 | SM8475 / Snapdragon 8+ Gen 1 | 4 KiB | `xnu/patches-mondrian/` |

The shim prints what the bootloader says about the phone, so the table can be
corrected from the device instead of from guesswork:

```
FACT memory reg0 0x0 0x80000000
FACT reg /soc/intc 0x17100000 0x10000 0x17180000 0x200000
FACT reg /soc/ufs_mem 0x1d84000 0x3000
```

```
python3 tools/mkadt.py mondrian.adt --board mondrian --facts facts.txt
```

## Building it

You need an unlocked phone, a Linux PC for the iOS root image, and a GitHub
account for the kernel build (public repositories get free macOS runner
minutes). **Everything on `userdata` is lost**; bootloaders, recovery, modem,
persist and the other firmware partitions are never touched.

### 1. Back up the phone

Boot a recovery (OrangeFox or any with adb root) temporarily and pull `persist`,
`modemst1`, `modemst2`, `fsg`, `fsc`, `boot`, `dtbo` and `vbmeta`; they hold
per-device calibration data. `.gitignore` already excludes `backup/`, `dtb/` and
`recovery/`. The shim also needs the stock DTB, which is inside the boot image:

```sh
python3 tools/unpack_bootv2.py backup/boot.img dtb/boot_unpacked   # -> dtb/boot_unpacked/dtb
```

### 2. Build the kernel

The workflow fetches xnu-8796.141.3, applies the patch series of the selected
board in order, and stages the pinned open-source libpthread, HFS and BearSSL
sources it needs:

```sh
gh workflow run xnu.yml -R YOU/ios-mondrian -f board=mondrian   # or board=sweet
gh run download RUN_ID -R YOU/ios-mondrian -n xnu-kernel-mondrian -D xnu/out
```

The same build runs on this Mac without the cloud, with the same pinned
`blacktop/darwin-xnu-build` tree and patch series:

```sh
bash tools/build-kernel-local.sh            # -> /tmp/kernel.development.mondrian
KERNEL_CONFIG=RELEASE bash tools/build-kernel-local.sh
```

It needs Xcode whose `iig` matches the xnu generation (Xcode 15 for xnu-8796),
`jq`, `cmake`, `ninja`, and a KDK in `/private/tmp/kdk/root` (or `KDKROOT=`).
The xnu checkout is reset before every build, so the series must apply to a
clean tree; a numbered patch that is skipped fails the script instead of
producing a kernel that is silently missing it.

To check a patch locally before spending a run, `tools/apply-series.py` applies
the whole series to a fresh xnu tree in seconds and `tools/xnu-cc.py` replays
the compile command of a single file from a previous CI log.

### 3. Build the iOS root image

Download the iPhone X (iPhone10,3) iOS 16.7.16 (20H392) IPSW from Apple. Then,
on Linux, with `apfs-fuse`, `hfsprogs` and sudo:

```sh
# OS, SystemOS and AppOS disk images from the IPSW (see BuildManifest.plist for their names)
tools/mkiosroot.sh OS.dmg SystemOS.dmg AppOS.dmg ios16-root.img 16G
sudo fsck.hfsplus -fy ios16-root.img
sudo mount -t hfsplus -o loop,force ios16-root.img /mnt/iosroot
sudo python3 tools/ios-root-tweaks.py /mnt/iosroot
sudo umount /mnt/iosroot
img2simg ios16-root.img ios16-root.simg
```

`mkiosroot.sh` copies the OS volume and both cryptexes into one case-sensitive
journaled HFS+ volume and adds the dyld cache links, the plain system keybag
and the log directories the daemons expect. `ios-root-tweaks.py` applies the
bring-up changes (skip Setup, seed activation, drop daemons that need missing
hardware, disable the watchdogs that kill slow apps); its header explains each
one. The device tree builder copies `/product` from the real iPhone X device
tree, which MobileGestalt needs — extract it once, without the whole IPSW:

```sh
python3 tools/remotezip.py IPSW_URL DeviceTree.d22ap.im4p research/ipsw-x/dt
ipsw img4 im4p extract research/ipsw-x/dt/Firmware/all_flash/DeviceTree.d22ap.im4p -o research/ipsw-x/d22ap.adt
```

### 4. Build the boot image

Needs `aarch64-linux-gnu-gcc` and `mkbootimg`.

```sh
python3 tools/mkadt.py shim/out/mondrian.adt --board mondrian
python3 tools/mkpayload.py xnu/out/kernel.development.mondrian \
    shim/out/mondrian.adt shim/out/payload.bin --board mondrian
BOARD=mondrian shim/build.sh shim/out/payload.bin   # -> shim/out/shim-boot.img
```

`--board sweet` and `BOARD=sweet` do the same for the reference phone. The boot
arguments default to the board's (`boards.Board.cmdline`); `--cmdline` overrides
them and `docs/MONDIAN_PORT.md` lists what they do.

### 5. Run, flash, read the log

```sh
tools/phone-boot.sh                    # phone in fastboot; writes no partition
tools/flash-root.sh ios16-root.simg    # userdata only; asks first
fastboot flash boot_b shim/out/shim-boot.img
```

A definite write follows the graded protocol in `docs/MONDIAN_PORT.md`
(volatile proof of the same image, `fastboot getvar current-slot`, verified
backup, write, read back). To read the kernel log, boot the viewer shim: it
reads the ring out of `userdata`, prints the last screenful and stops, and
writes nothing to the phone. A recovery with adb reads the same area with
`tools/ios-log-pull.sh`.

```sh
tools/phone-deploy.sh logview          # shim with LOGVIEW=1
fastboot boot /tmp/boot-mondrian.img   # photograph; power+vol-down to leave
```

## Repository layout

| Path | What |
| --- | --- |
| `shim/` | Bare-metal boot shim (C + asm) packed as an Android boot.img v2; `board.h` holds the per-board constants, `console.c` the text console, `ufs.c` the read-only UFS probe and the log viewer |
| `xnu/patches/` | the XNU patch series for sweet, plus staging scripts for libpthread, HFS and BearSSL |
| `xnu/patches-mondrian/` | the XNU patch series for mondrian (see its README for the state of each patch) |
| `.github/workflows/xnu.yml` | kernel CI build (`board` input) |
| `tools/build-kernel-local.sh` | the same build on this Mac (same pinned dxb tree and series) |
| `tools/boards.py` | the board table: MMIO, memory, CPU topology, page size, boot args |
| `tools/mkadt.py`, `mkpayload.py` | generate the Apple Device Tree / pack kernel + ADT + boot args |
| `tools/apply-series.py`, `check-patches.sh`, `port-series.py` | apply, validate and port patch series |
| `tools/mkiosroot.sh`, `ios-root-tweaks.py` | build the HFS+ iOS root from the IPSW images |
| `tools/phone-boot.sh`, `phone-deploy.sh`, `flash-root.sh` | volatile boot, boot-partition deploy, root flash |
| `tools/ios-log-pull.sh`, `ios-log.py`, `ios-crash.py` | read and symbolicate the persistent kernel log |
| `tools/qemu-ios.py`, `qemu-triage.py` | host boots of the same payload, with console text decoding |
| `tools/adt.py`, `remotezip.py`, `unpack_bootv2.py`, `sparsediff.py` | helpers |
| `docs/MONDIAN_PORT.md` | the port plan for the POCO F5 Pro |
| `docs/MONDIAN_TOUCH.md` | the touch bring-up: live-tree facts and milestones |
| `NOTES.md` | port state, measured hardware facts and the traps already paid for |

Not in git: partition backups, live device trees, recovery images, Apple
firmware and root images, build trees. They hold device serials and calibration
data, or Apple's copyrighted files.

## Credits

Built on Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs),
[BearSSL](https://bearssl.org),
[blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build),
[ipsw](https://github.com/blacktop/ipsw), Qualcomm/Xiaomi's published Linux
kernel sources for the hardware details, and
[OrangeFox Recovery](https://orangefox.download). iOS itself is Apple's and is
not distributed here.

The sweet half of this repository is the work of
[dipa-studio](https://github.com/dipa-studio); this fork adds the mondrian
(POCO F5 Pro) port on top of it. Other ports this work learned from are listed
in `NOTES.md`.
