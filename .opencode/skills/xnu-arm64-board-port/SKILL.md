---
name: xnu-arm64-board-port
description: Port XNU (arm64) to a new Qualcomm phone: memory window, pmap and low globals, GIC, generic timer, early console, and the constraints already measured on mondrian. Use for any change to pmap, adt/mkadt, the shim's board facts, early boot order, or "why does XNU not get past <early milestone> on this phone".
---

# Porting XNU to a new arm64 phone

The working reference is the sweet port (Redmi Note 10 Pro). mondrian (POCO F5
Pro, SM8475) is the port in progress. Read `NOTES.md` and
`docs/MONDIAN_PORT.md` first: they carry the live state, this file carries the
rules.

## What the first months cost, and why

Almost every failure in this port has been an address, a size, or an
assumption about a clock. Not one has been a logic bug in XNU. Check data
before code.

## Memory

- mondrian runs **PAGE_SHIFT 14** (16 KiB), the granule iOS userland and its
  dyld shared cache are built for. Do not mix numbers from a 4 KiB build.
- The kernel's usable window is `0xB0000000` + `0x46000000`. It cannot shrink
  much below `0x3a000000`: the physmap of the window has to fit inside the
  window itself.
- The early framebuffer is aliased into the **low globals** region, whose size
  is `pmap`'s `low_global_vr_size` (sweet reserves `0x2000000` for that alias).
  A too-small value shows up as a fault on the first console write, not at
  boot.
- Memory that belongs to someone else must be removed from the free lists, not
  just avoided. `0083` records the ADT `mondrian-fbcon` `reg` in `pe_serial.c`
  and makes `pmap_next_page()`, `initialize_ram_ranges()` and
  `pmap_free_pages_span()` skip it. Without that the allocator hands the panel
  memory to a kext and the screen becomes garbage.
- `kmem_alloc_contig()` does not scale: 1 page and 36 pages return, 256 pages
  (1 MiB) never returns on mondrian. Keep contiguous requests at or below
  ~128 KiB and build larger buffers from a fixed contiguous pool instead.
- The panel is written through the console alias (`mondrian_early_fb_va()`),
  never through an `IOMemoryDescriptor` over its physical range: a device
  pager on VM-managed pages corrupts the pmap PV lists and panics in
  `pmap_remove_pv`. `PE_initialize_console(kPEDisableScreen)` unmaps that
  alias and panics the same way; stop the screen console with
  `disableConsoleOutput` instead.

## Time

- `pexpert/arm/pe_identify_machine.c` takes the timebase frequency from the
  ADT (`timebase-frequency`, 19.2 MHz here). There is no `CNTFRQ_EL0` read.
- The vtimer PPI (27) does **not** deliver out of the box, and that breaks
  every timed wait (`tsleep`, `usleep`, dispatch timers, CoreAnimation's frame
  pacing) while the boot still looks alive. `0116` fixes it: end and clear the
  PPI (`GICR_ICACTIVER0`/`GICR_ICPENDR0`), clear its Group 1 secure modifier
  (`GICR_IGRPMODR0`), zero `ICC_AP1R0_EL1`, then enable it. Check the timer
  IRQ counter and DAIF in the sampler line instead of assuming.
- Before the GIC is up, `delay()`/`mach_absolute_time()` can block the boot
  (0082). Keep early waits bounded by spin counts
  (`ufs_calibrate_spins()` in `bsd/dev/mondrian_ufs.c` is the model), never by
  a deadline computed from a possibly frozen counter.

## Interrupts

- The DT `interrupts` property carries GIC SPIs 0-based; XNU's INTIDs are
  SPI + 32. Off-by-32 gives a handler that never fires, silently.
- QEMU (`tools/qemu-ios.py`, `docs/QEMU_TESTING.md`) uses GICv3 with
  `-cpu cortex-a76`; a change that works there still needs the live dtb check
  (GICD/GICR addresses differ, and the QEMU timebase is 62.5 MHz, not 24).
- `pe_mondrian_gic_dump()` and `mondrian_irq_dump()` exist for a reason: call
  them from a diagnostic build rather than guessing which line is wrong.

## The ADT is the kernel's only hardware description

- `tools/mkadt.py` emits the Apple Device Tree XNU actually consumes: UART,
  GIC, timers, `/chosen`, `pram`, `mondrian-fbcon`, `/arm-io/disp0`. Every
  MMIO address comes from `tools/boards.py`.
- A change to a hardware fact is a change to **two** tables: `tools/boards.py`
  and `shim/board.h`. They are duplicated on purpose (the shim cannot import
  Python) and drift silently otherwise.
- `mkadt.py` and `mkpayload.py` refuse boards whose values are still
  provisional. `--allow-provisional` is the deliberate escape hatch, not a
  build flag.
- The real DTB is reference data for filling those tables, never an input to
  the build. See the `qualcomm-device-tree` skill for reading it.
- An MMIO node's `reg` can cover a superset with holes. Cape's
  `pinctrl@f000000` declares 16 MB, but the pin registers start at
  `0x0f100000` (mainline `pinctrl-sm8450`); a read at `0x0f014000` does not
  abort, it wedges the interconnect, the timer interrupt stops and the
  watchdog resets the phone. Cross-check a register base against mainline's
  driver for the SoC before the first read, and flush the ring before it.

## Order of an early boot, as a diagnostic ladder

1. shim (prints the live device tree it was given)
2. XNU entry, boot args, ADT parse
3. pmap / low globals / physmap
4. early console (UART, then the ABL framebuffer)
5. interrupts (GIC, timer)
6. storage -> BSD root

Know which rung a boot died on before touching anything. The console lines in
`pexpert/arm/pe_serial.c` are the ladder; keep them when adding a platform.

## Before you spend a CI run

- `tools/check-patches.sh` locally (see the `xnu-patch-stack` skill).
- Cross-compile single files when possible.
- A CI run is 8-19 minutes; a boot cycle is flash + photo. Make one change
  that answers one question, and put the diagnostics for the *next* question
  in the same build when they are free.
