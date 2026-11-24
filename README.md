# ios-mondrian

**Apple's iOS 16 running on a POCO F5 Pro.**

Fork of [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet), which
ports Apple's open-source XNU (xnu-8796, the iOS 16 generation) to the Xiaomi
Redmi Note 10 Pro (`sweet`, SM7150) and runs the unmodified iOS 16.7.16 userland
of the iPhone X on it: launchd, the daemons, backboardd, SpringBoard and apps.

This fork targets the **POCO F5 Pro / Redmi K60** (`mondrian`, Qualcomm SM8475 /
Snapdragon 8+ Gen 1): ARMv9.0, 16 KiB pages, a UFS 3.1 host, a command-mode
AMOLED and a Goodix touch on SPI.

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
| UFS root device | done (UFSHCI 2.1) | **reads and writes** (UFS 3.1) |
| iOS root mount | done | **done** (non-journaled HFS+ in `userdata`) |
| Display | done (LCD, DSC) | **command-mode AMOLED, 120 Hz**; the kernel kicks the panel |
| Touch | done (Goodix on I²C) | **done** (Goodix on SPI); home and app-switcher gestures |
| Keys and battery | done (PM6150) | keys work (SPMI); battery level published from the VADC |
| Boot menu | n/a | bypassed: the shim boots iOS directly; no Android dual boot |
| iOS userland | boots to the home screen | yes (GPU via Mesa/freedreno GLES, touch, Settings, Bluetooth) |

On `sweet`, the stock bootloader boots the shim volatile, XNU mounts a journaled
HFS+ root from `userdata` read/write, and the userland reaches the home screen
(CPU rendering, no GPU/Wi-Fi/cellular/audio/camera/SEP, navigation gestures still
broken). That is the target; the series, boot arguments and root-image tooling
are shared (`xnu/README.md`).

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
at `0xb8000000` on mondrian (120 Hz tick), 1080x2400 at `0x9c000000` on sweet
(30 Hz) — and keeps the whole log in a 4 MiB ring at the end of `userdata`
(`0096`). The ring is written from the UFS path, so a boot reset before userland
writes leaves the previous ring: unchanged is not proof of failure.

## Boards

The shim, the device tree builder and the payload packer take a `--board`
argument. The numbers live in [`tools/boards.py`](tools/boards.py) and, for the
shim, in `shim/board.h` (change both together).

| board | phone | SoC | page size | kernel series |
| --- | --- | --- | --- | --- |
| `sweet` | Redmi Note 10 Pro | SM7150 / Snapdragon 732G | 16 KiB | `xnu/patches/` |
| `mondrian` | POCO F5 Pro / Redmi K60 | SM8475 / Snapdragon 8+ Gen 1 | 16 KiB | `xnu/patches-mondrian/` |

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

Back up the calibration data (`persist`, `modemst1`, `modemst2`, `fsg`, `fsc`,
`boot`, `dtbo`, `vbmeta`) from a rooted Android or an EDL tool: no recovery boots
here (see the recovery note in AGENTS.md), so that is the only route. `.gitignore` already excludes `backup/`, `dtb/` and
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

The same build runs locally from a Mac or Windows/WSL2, with the same pinned
tree and series; both reset the xnu checkout first, so a skipped patch fails the
build instead of producing a kernel that silently lacks it:

```sh
bash tools/build-kernel-local.sh   # macOS: Xcode 15's iig, jq, cmake, ninja, a KDK
tools/wsl/build-kernel.sh          # Windows/WSL2: no Mac, no Xcode (docs/BUILD_LINUX.md)
```

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
sudo umount /mnt/iosroot && sudo fsck.hfsplus -fy ios16-root.img
img2simg ios16-root.img ios16-root.simg
```

`mkiosroot.sh` copies the OS volume and both cryptexes into one case-sensitive
HFS+ volume, journal off before boot (`NOTES.md`), and adds the dyld
cache links, the system keybag and the log directories the daemons expect. `ios-root-tweaks.py` applies the
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
arguments default to the board's (`boards.Board.cmdline`, listed in
`docs/MONDIAN_PORT.md`); `--cmdline` overrides them.

### 5. Run, flash, read the log

```sh
tools/phone-boot.sh                    # phone in fastboot; writes no partition
tools/flash-root.sh ios16-root.simg    # userdata only; asks first
fastboot getvar current-slot           # must be b
fastboot flash boot_b shim/out/shim-boot.img
# No recovery boots here: `fastboot boot` refuses the OrangeFox images and
# `boot_b` lands in fastboot; vendor blobs come from the ROM instead
# (tools/super-extract.py). `fastboot.exe` takes `C:\...`, never `/mnt/c`.
tools/build-mondrian-ui-hook.sh out/gpu/mondrian-ui-hook.dylib
# a kernel build embeds it (tools/gen-glblob.py); glblob=1 boots that copy
sudo tools/install-ui-hook.sh ios16-root.img DYLIB   # or burn it into the image
python3 tools/mk-simg.py ios16-root.img ios16-root.simg
```

Editing the image only needs root for the mount; `flash-root.sh` reuses an
existing `.simg`, so remake the sparse file by hand. A definite write follows
the graded protocol in `docs/MONDIAN_PORT.md`. With `usb=2` the kernel runs a
USB gadget: `tools/ios-usbnet.sh` gives the link 192.168.7.1 and NATs it (the
hook adds the phone's route, so the cable is its Internet); `tools/usb-ring.py`
dumps the ring, screenshots the panel, injects input and reboots to the
bootloader, and `tools/phone-log.sh` reads the ring through the recovery.

A hook change needs no image round trip: a kernel build with
`out/gpu/mondrian-ui-hook.dylib` present embeds it (`tools/gen-glblob.py`);
`glblob=1` writes it into `/private/var/vm`, and `kern_exec` prefers that copy.

```sh
tools/phone-deploy.sh logview          # shim with LOGVIEW=1
fastboot boot out/boot-mondrian.img    # photograph; power+vol-down to leave
tools/phone-log.sh out/boot-mondrian.img ring.txt
```

## Repository layout

| Path | What |
| --- | --- |
| `shim/` | Bare-metal boot shim (C + asm) packed as an Android boot.img v2; `board.h` holds the per-board constants, `console.c` the text console, `ufs.c` the read-only UFS probe and the log viewer |
| `xnu/patches/` | the XNU patch series for sweet, plus staging scripts for libpthread, HFS and BearSSL |
| `xnu/patches-mondrian/` | the XNU patch series for mondrian (see its README for the state of each patch) |
| `.github/workflows/xnu.yml` | kernel CI build (`board` input) |
| `tools/build-kernel-local.sh` | the same build on this Mac (same pinned dxb tree and series) |
| `tools/wsl/` | the same build on Windows/WSL2 without a Mac (`docs/BUILD_LINUX.md`) |
| `tools/boards.py` | the board table: MMIO, memory, CPU topology, page size, boot args |
| `tools/mkadt.py`, `mkpayload.py` | generate the Apple Device Tree / pack kernel + ADT + boot args |
| `tools/apply-series.py`, `check-patches.sh`, `port-series.py` | apply, validate and port patch series |
| `tools/mkiosroot.sh`, `ios-root-tweaks.py` | build the HFS+ iOS root from the IPSW images |
| `tools/phone-boot.sh`, `phone-deploy.sh`, `flash-root.sh` | volatile boot, boot-partition deploy, root flash |
| `tools/ios-log-pull.sh`, `ios-log.py`, `ios-crash.py` | read and symbolicate the persistent kernel log |
| `tools/qemu-ios.py`, `qemu-triage.py` | host boots of the same payload, with console text decoding |
| `tools/adt.py`, `remotezip.py`, `unpack_bootv2.py`, `sparsediff.py`, `hfs-audit.py` | helpers; `hfs-audit.py` checks what `fsck` does not: bitmap against the header's count, forks sharing blocks, sizes that do not fit |
| `docs/MONDIAN_PORT.md` | the port plan for the POCO F5 Pro; donors and licences in `docs/REFERENCE_PORTS.md` |
| `docs/MONDIAN_TOUCH.md` | the touch bring-up: live-tree facts and milestones |
| `docs/BUILD_LINUX.md` | building the kernel on Windows/WSL2, with no Mac |
| `NOTES.md` | port state, measured hardware facts and the traps already paid for |

Not in git: partition backups, live device trees, recovery images, Apple
firmware, root images and build trees — serials, calibration data or Apple's files.

## Credits

Built on Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs),
[BearSSL](https://bearssl.org), [blacktop](https://github.com/blacktop)'s
darwin-xnu-build and ipsw, Qualcomm/Xiaomi's published Linux kernel sources
for the hardware details, and [OrangeFox Recovery](https://orangefox.download).
iOS itself is Apple's and is not distributed here.

The sweet half of this repository is the work of
[dipa-studio](https://github.com/dipa-studio); this fork adds the mondrian
(POCO F5 Pro) port on top of it. It also builds on HackiOS, ios-topaz,
OneiOS/iOSPlus10, UniXNU, the MIX Fold 2 Wi-Fi work and the Pixel 5 port;
`docs/REFERENCE_PORTS.md` says what each solves, its evidence and its
licence.
