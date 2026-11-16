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
tools/wsl/qemu-run.sh 240          # ADT, payload, disk, run and summary, in one go
tools/wsl/qemu-run.sh 240 && less /root/qemu-run/serial.txt
```

The script exists because the recipe has five steps and four traps. The pieces,
when one of them has to change: `mkadt.py --qemu --board mondrian` (ADT),
`mkpayload.py ... --cmdline '<one line>' --allow-silent-boot` (payload),
`simg2img backup/ios-root.simg /root/ios-root.raw` (the 16 GB root, once) and
`qemu-ios.py ... --board mondrian --kernel xnu/out/kernel.development.mondrian
--disk /root/ios-root.raw`.

The userland flags are the phone's (`tools/boards.py`), not QEMU's: without
`launchd_unsecure_cache=1` and `unentitled_ios_sim_launch=1` the guest mounts
the root, execs `/sbin/launchd`, and init exits before it can start anything.

`--disk` serves the image as virtio-blk, `snapshot=on` (the volume is not
journaled; a run killed mid-flight leaves errors the next boot inherits), and
forces it onto `virtio-mmio-bus.0`: `mkadt.py` states the first transport
(`0xa000000`) and without `bus=` QEMU hands the device to the last. The kernel
prints `MONDRIAN VBLK: virtio-blk, N MiB` when the two agree. Under TCG a boot
to `bsd_init` takes a minute, so `--secs 240` is the minimum worth typing.
The run directory has to be on the Linux side: QEMU's QMP socket fails to bind
under `/mnt/c` ("Operation not supported") and the run exits 1 before the guest
starts.

A run carries the dylib the *image* holds, not the kernel's blob:
`tools/wsl/hfs-tool.sh put IMAGE /private/var/vm DIR` replaces it, or a stale
copy answers for the hook.

**The command line must be one line.** A multi-line string inside the shell
quotes puts a newline after `rd=vblk0`, `rdBootVar` stops being the string
`vblk0`, the guest falls into the generic `IOBSDNameMatching` path and waits for
a disk for ever — which reads exactly like a virtio driver that never probed.
`tools/wsl/qemu-run.sh` builds it in one line and runs the whole thing.

What a good run looks like (measured): `MONDRIAN VBLK: virtio-blk, 16384 MiB`,
`hfs: mounted iOSRoot on device b(1, 0)`, `exec launchd`, then the ignition log
and hundreds of `exec`s. `result.json` still says `incomplete_decode` because
there is no panel to read the framebuffer from; that is the decoder, not the
boot.

Options worth knowing: `--board mondrian` picks the 1440x3200 panel and the
`max` CPU model (the board is armv8.5 and touches `DIT`, which `cortex-a76`
lacks); `--live-serial` streams the console; `--gdb` starts halted with a stub
on 1234; `--hmp "xp/8gx 0x<pa>"` reads guest memory after the stop.

## Reading the result

`no_panic_observed` means "no visible panic in the framebuffer snapshot", not
"booted": with `--qemu` read `serial.txt` and `qemu.log`/`qemu-triage.py` when
its last line is not enough. With no panel, `result.json` says
`incomplete_decode` on every run; that is the text decoder, not the boot. Two
traps: the ADT's CPU node must carry MPIDR 0 (the boot core is 7) and
`phystokv()` panics outside the window.
