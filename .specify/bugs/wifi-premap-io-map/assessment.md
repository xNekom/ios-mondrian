# Bug Assessment: Wi-Fi premap panics in io_map()'s NOFAIL allocation

- **Slug**: wifi-premap-io-map
- **Created**: 2026-11-26
- **Source**: pasted text (device panic console, `w43`/`w44` boots)
- **Verdict**: valid (panic reproduced); root cause likely valid, needs one confirming boot
- **Severity**: high (a Wi-Fi boot does not reach SpringBoard)

## Report (summarized)

With `mondrianwifi=1` on series 0485, the boot stops on a kernel panic whose
HUD line is the format string

```
MONDRIAN PANIC: kmem_%s(%p, %zd, 0x%x): failed with %d @%s:%zd
```

with caller `0xfffffe0007c04ad0` (`__kmem_failed_panic`) and arguments
`what="alloc"`, `map=0xfffffe1010f55c90`, `size=0x4000`,
`flags=0x10002x` (transcribed; `io_map()` passes
`KMA_NOFAIL|KMA_PAGEABLE|KMA_PERMANENT`).

## Symptom

A Wi-Fi boot on 0485 panics (or never answers the ring and falls back to
`boot_b`). Expected: stage 14 or later over `wifistage`, no panic. The same
kernel without `mondrianwifi=1` boots to SpringBoard, and 0484 reaches
`wifistage 14` with Wi-Fi enabled.

## Reproduction

1. Build the series with 0485 and boot it from RAM with the Wi-Fi boot args
   (`mondrianwifi=1 mondrianwififw=1 mondrianwifibypass=1
   mondrianwifidelay=0`).
2. The ring never answers; the phone falls back to `boot_b`. On 0485 the panel
   shows the panic above.
3. Build 0484: the same boot answers `wifistage 14` and the worker stops later,
   in `wifi_w10_probe()`'s own `ml_io_map()` of GPIO 82.

## Suspected Code Paths

- `bsd/dev/mondrian_wifi.c:mondrian_wifi_premap_pins()` — 0485 adds a seventh
  `ml_io_map()` (the SW_CTRL page) to the pin premap.
- `osfmk/arm/io_map.c:io_map()` — the only `kmem_alloc()` with
  `KMA_NOFAIL` that runs after startup, and it allocates from `io_submap`.
- `Fixes`: `0486-mondrian-wifi-pin-pages.patch` removes that map.

## Root Cause Hypothesis

Confidence **high** that the failing call is `io_map()`: no other post-startup
`kmem_alloc*` passes `KMA_NOFAIL`, and `0x4000` is one 16 KiB mapping (the
`map` value is a heap `vm_map`, i.e. `io_submap`, not `kernel_map`).
Confidence **medium** that 0485's extra mapping is the trigger: 0484 proves the
six pin maps and the worker's later 1 MiB SMMU mapping fit, so the submap is
not simply full, and 0485 differs only by the seventh map.

## Proposed Remediation

**Preferred** (0486): every pin derives from one 16 KiB TLMM window instead of
one mapping per pin, and GPIO 82 (sw_ctrl) shares GPIO 80's window, so the
premap spends four mappings and no seventh. The worker's W10 fallback no
longer maps its own page (a late map from the worker hangs).

**Alternatives**:
- Map the three GPIO 80-82 registers with one `ml_io_map()` and keep the other
  pins as they are: same effect on the failing map, less code churn.
- Add per-map breadcrumbs and flush after each: diagnostic only.

**Files likely to change**:
- `xnu/patches-mondrian/0486-mondrian-wifi-pin-pages.patch` (committed)

**Tests to add or update**:
- One boot with the Wi-Fi args: the ring must answer with the built banner,
  `wifistage` must be >= 14, and `prev` must hold no `MONDRIAN PANIC` line.

## Risks & Considerations

- If the panic is not the seventh map, 0486 does not fix it and the next
  diagnostic is a per-map breadcrumb written to the log before each
  `ml_io_map()`, read with `prev` after the fallback.
- The `io_submap` is 8 MiB for the whole kernel; the Wi-Fi driver must not
  add mappings for windows that overlap an existing one.

## Open Questions

- Which exact `ml_io_map()` failed: the new SW_CTRL one, or a later premap map
  made short by it? A boot with per-map breadcrumbs answers it.
- Does `io_submap` fragmentation, rather than usage, matter at this point of
  the boot?
