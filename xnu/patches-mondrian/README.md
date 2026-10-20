# The mondrian patch series

This is the XNU patch series for the **POCO F5 Pro / Redmi K60**
(`mondrian`, Qualcomm SM8475 / Snapdragon 8+ Gen 1). It is a parallel series
to `xnu/patches/`, which stays the (working) `sweet` series: the two boards
are different SoCs and the patches are not interchangeable.

The CI picks the series with the `board` input of `.github/workflows/xnu.yml`:

| board | series | machine config |
| --- | --- | --- |
| `sweet` (default) | `xnu/patches/` | `SWEET` |
| `mondrian` | `xnu/patches-mondrian/` | `MONDRIAN` |

## What is in here

| # | Patch | State |
| --- | --- | --- |
| 0001 | `mondrian-machine-config` | **done**: the XNU board config for SM8475 (ARMv9.0, 4 KiB pages, GICv3 with eight redistributors, no PAC) |

## What is still missing

Everything else. The port order and the per-patch deltas are in
[`docs/MONDIAN_PORT.md`](../../docs/MONDIAN_PORT.md); the short version is:

1. the generic parts of the sweet series (mockfs, AMFI, HFS, BearSSL, the
   console, the crash log) are board independent and can be taken over as
   they are, with `SWEET` renamed to `MONDRIAN`;
2. the parts that talk to the hardware (UFS, touch, keys, display) have to
   be rewritten, because SM8475 has a UFS 3.1 host, a Goodix touch on SPI
   instead of I2C, a PM8008 instead of the PM6150 and an AMOLED panel on DSI
   instead of an LCD in DSC video mode.

`tools/port-series.py` does the mechanical part of (1): it takes a patch from
the sweet series, renames the board identifiers and tells you which hunks
still need hardware work.
