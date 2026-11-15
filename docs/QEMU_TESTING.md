# QEMU testing

`tools/qemu-ios.py` boots the same payload (`mkpayload.py` output) on QEMU's
`virt` machine, so kernel changes can be checked without touching the phone. It
does what the shim does: place the segments, the ADT and the boot arguments at
their physical addresses and jump. It covers the physical memory layout, the
GICv3, the virtual timer, a PL011 console and virtio-blk, and it writes:

| file | content |
| --- | --- |
| `serial.txt` | the console, from QEMU's PL011 (`mkadt.py --qemu` only) |
| `fb.png`, `fb.txt` | the panel, or its text decoded with the kernel's font |
| `regs.txt` | register state, plus the output of every `--hmp` command |
| `qemu.log` | guest exceptions (interrupts, aborts, translation faults) |
| `result.json` | `no_panic_observed`, `panic`, `blank_screen` or `incomplete_decode` |

Not emulated: Qualcomm XPU/TZ protections, the ABL, the panel and its MDP, the
PMIC, and the PSCI conduit (QEMU uses `hvc`).

## What the emulator does not have, and what that costs

Every one of these was a boot that died for a reason that is not a kernel bug:

- **No MDP.** `mkadt.py --qemu` leaves `disp0` out. With the node, the
  framebuffer driver reads a register that is not there, takes a synchronous
  external abort, and QEMU re-executes the instruction for ever.
- **No UART on the board, and no panel either.** The phone's console is the
  panel, so `--qemu` emits `mondrian-qemu-uart` (PL011 at `0x09000000`) instead
  of `mondrian-fbcon`, and `pe_serial.c` drives it as one more serial device.
  The HUD (panic report, `KABORT`, the memory lines) paints the panel; with no
  panel node (`mondrian_panel_absent`) those rows go to the console, or a guest
  panic is silent.
- **No block device.** `bsd/dev/mondrian_virtio.c` is virtio-blk over the modern
  virtio-mmio transport, polled: the node carries no interrupt, so the GIC never
  forwards the line. The image stays on the host, so a 16 GB root fits here.
- **No PMIC.** The SPMI windows are board constants, not tree entries, so the
  RTC read in `IOKitInitializeTime()` aborts. `mondrianspmi=0` skips it.

## Build a payload and run it

```sh
python3 tools/mkadt.py /tmp/qemu.adt --qemu --board mondrian
python3 tools/mkpayload.py xnu/out/kernel.development.mondrian /tmp/qemu.adt \
    /tmp/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -noprogress rd=vblk0 mondrianspmi=0
        launchd_unsecure_cache=1 unentitled_ios_sim_launch=1 rootrw=1
        ignition_level=1 wdt=-1 mondriankill=quiet' \
    --board mondrian --allow-silent-boot

simg2img backup/ios-root.simg /root/ios-root.raw   # 16 GB; served snapshot=on
python3 tools/qemu-ios.py /tmp/payload.bin /tmp/qemu-run --secs 240 \
    --board mondrian --kernel xnu/out/kernel.development.mondrian \
    --disk /root/ios-root.raw
```

The userland flags are the phone's (`tools/boards.py`), not QEMU's: without
`launchd_unsecure_cache=1` and `unentitled_ios_sim_launch=1` the guest mounts
the root, execs `/sbin/launchd`, and init exits before it can start anything.

`--disk` serves the image as virtio-blk, `snapshot=on`, and forces it onto
`virtio-mmio-bus.0`: without `bus=` QEMU hands the device to the *last* free
transport (`0xa003e00`), while `mkadt.py` states the first (`0xa000000`). Both
halves have to agree, and the kernel prints `MONDRIAN VBLK: virtio-blk, N MiB`
when they do. The snapshot matters: the volume is not journaled, so a run killed
mid-flight leaves it dirty and the next boot inherits the errors as runtime
corruption. Under TCG a boot to `bsd_init` takes a minute, so `--secs 240` is
the minimum worth typing.

Options worth knowing: `--board mondrian` picks the 1440x3200 panel and the
`max` CPU model (the board is armv8.5 and touches `DIT`, which `cortex-a76`
lacks); `--live-serial` streams the console; `--gdb` starts halted with a stub
on 1234; `--hmp "xp/8gx 0x<pa>"` reads guest memory after the stop, where a
kernel variable's physical address is
`VA - VM_KERNEL_LINK_ADDRESS + phys_base + 0x4000`.

## Environment knobs

| variable | effect |
| --- | --- |
| `QEMU_PHYS_BASE`, `QEMU_MEM_SIZE` | another window of RAM (default `0xb0000000`/`0x4d000000`; the phone's own shape is `0x100000000`/`0x180000000`) |
| `ADT_SEED` | pin the random seed the physmap slide derives from |
| `ADT_MEMORY=0`, `DT_CPUS=1` | leave `/memory` out of the tree, or emit a single CPU node |

## Reading the result

`no_panic_observed` means "no visible panic in the framebuffer snapshot", not
"booted": with `--qemu` read `serial.txt`, which has the whole console, and use
`qemu.log`/`qemu-triage.py` when its last line is not enough. Two traps this
machine found: the ADT's CPU node must carry MPIDR 0 (the phone's boot core is
7), and `phystokv()` panics on any address outside the window.
