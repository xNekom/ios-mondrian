# Audio on mondrian

The ADSP is up through PAS1. `mondrianadsp=1` starts a worker that reads the
joined `/private/var/vm/adsp.mbn` (`tools/adsp-image.py` joins the stock
`adsp.mdt` and `adsp.bNN`), maps the APPS-ADSP windows, and calls PAS1:
`init_image`, `mem_setup`, the ELF segment copies and `auth_and_reset`.
Measured 2026-11-27: every call returns 0, and the ADSP's `slave-kernel`
SMP2P entry answers `0x6` (READY | HANDOVER, the donor's bits 1 and 2) two
milliseconds after the reset. The `master-kernel` outbound SMP2P item and its
LPASS doorbell go in before the load, because the ADSP looks for it at boot.

The QMP `load_state` vote and the RPMh `lcx`/`lmx` votes are **not** needed for
this step on mondrian: the ADSP answers with the AOSS mailbox still closed.
They stay the fallback for a service that needs the rails.

## Traps

- **The windows cannot come from `ml_io_map()`.** It allocates from the fixed
  8 MiB `io_submap` with `KMA_NOFAIL`: the 2 MiB SMEM map after 49 MiB of
  carveout chunks either panics the boot in `kmem_alloc` or wedges the worker
  there. Map SMEM and the MMIO windows with `ml_io_map_unmappable()` and the
  attributes `ml_io_map` used (`VM_WIMG_IO`), and the carveout in 2 MiB
  `VM_WIMG_WCOMB` chunks.
- **`pmap_find_phys()` returns a ppnum in `PAGE_SIZE` units** (16 KiB here),
  not a 4 KiB page number. Convert with `ptoa_64()`; `pn << 12` hands TZ a
  buffer 4x below the metadata and `init_image` fails with transport
  `0xffcffff6`.
- **Map in the worker, not in `mondrian_log_start`.** A fault in the premap
  kills the boot before USB answers and leaves no ring on disk, so the failure
  is silent. The worker starts after the probes and `adsp_log()` flushes after
  every line.
- The firmware must be pushed to `/private/var/vm/adsp.mbn`; the worker waits
  up to 60 s for it and logs every segment it copies.

## What is next

GLINK over the SMEM FIFO, then the GPR channel that enumerates the audio
services, then WCD938x (SoundWire) and the two AW88261 amplifiers. The donor
ladder and the register references are in `docs/REFERENCE_PORTS.md`; the
`master-kernel`/`slave-kernel` SMP2P names and the ready bits come from the
zizhan ADSP worker.
