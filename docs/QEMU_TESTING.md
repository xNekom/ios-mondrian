# QEMU testing

`tools/qemu-ios.py` boots the same payload (`mkpayload.py` output) on QEMU's
`virt` machine, so most kernel changes can be checked without touching the
phone. It emulates what the shim does: place the segments, the ADT and the
boot arguments at their physical addresses and jump.

It covers the physical memory layout, the GICv3, the virtual timer and the
framebuffer, and it writes:

| file | content |
| --- | --- |
| `fb.png` | the panel as the guest left it |
| `fb.txt` | the console text, decoded with the kernel's own font (needs `--kernel`) |
| `regs.txt` | register state, plus the output of every `--hmp` command |
| `qemu.log` | guest exceptions (interrupts, aborts, translation faults) |
| `result.json` | `no_panic_observed`, `panic`, `blank_screen` or `incomplete_decode` |

Not emulated: Qualcomm XPU/TZ protections, the ABL, the real panel, and the
PSCI conduit (QEMU uses `hvc`). Those are decided by the hardware.

## Setup

```sh
python3 tools/qemu-ios.py --check-env          # reports what is missing
brew install qemu llvm                         # macOS; pacman/apt/dnf on Linux
```

## Build a payload and run it

```sh
python3 tools/mkadt.py /tmp/qemu.adt --qemu
python3 tools/mkpayload.py xnu/out/kernel.development.sweet /tmp/qemu.adt \
    /tmp/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=md0'

python3 tools/qemu-ios.py /tmp/payload.bin /tmp/qemu-run --secs 20 \
    --kernel xnu/out/kernel.development.sweet
```

Options worth knowing:

- `--board mondrian` selects the 1440x3200 framebuffer and the `max` CPU model
  (the board is armv8.5 and touches `DIT`, which `cortex-a76` does not have).
- `--live-serial` streams the serial console to the terminal.
- `--fail-on-panic` exits 2 on a visible panic and 3 on a blank or undecodable
  screen; useful in CI.
- `--gdb` starts halted with a gdb stub on port 1234:
  `lldb -o "gdb-remote 1234" -o "register read -a"`.
- `--hmp "xp/8gx 0x<pa>"` reads guest physical memory after it stops. Any kernel
  variable can be read this way: `llvm-nm` gives the link address, and the
  physical address is `VA - VM_KERNEL_LINK_ADDRESS + phys_base + 0x4000`.

`tools/qemu-triage.py <outdir> <kernel>` prints the first exception and the
symbol it happened in, which is usually enough to name the culprit.

## Environment knobs

| variable | effect |
| --- | --- |
| `QEMU_PHYS_BASE`, `QEMU_MEM_SIZE` | try another window of RAM (this is how the mondrian window was chosen) |
| `ADT_SEED` | pin the random seed the physmap slide derives from |
| `ADT_MEMORY=0` | leave `/memory` out of the tree |
| `DT_CPUS=1` | emit a single CPU node |

## Reading the result

The screen rows are circular and the console blanks once per screenful, so
`no_panic_observed` means "no visible panic in that snapshot", not "booted".
Use `qemu-triage.py`, the `--hmp` reads or the `--gdb` stub to find out where
it actually stopped. A 12 s run can miss panics that follow the 30 s `IORTC`
wait: use at least 45 s, or a board that skips that wait.
