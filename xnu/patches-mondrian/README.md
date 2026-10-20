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
| 0002 | `mondrian-master-config` | **done**: `config/MASTER.arm64.mondrian`, the open source arm64 assembly and pmap, no kpc |
| 0003-0055 | the generic half of the sweet series | **done**: RAM disk root, AMFI, HFS+, BearSSL, the console, the crash log, the HID services, the SMP and the iPhone identity |

The series applies cleanly to a fresh xnu-8796.141.3 tree:

```
git clone --depth 1 --branch xnu-8796.141.3 \
    https://github.com/apple-oss-distributions/xnu.git xnu8796
tools/apply-series.py xnu8796 --series xnu/patches-mondrian --machine MONDRIAN
```

## What is still missing

The patches that talk to the hardware of the sweet phone. They are listed
in `HARDWARE_PATCHES` of `tools/port-series.py` with what each of them
needs, and `docs/MONDIAN_PORT.md` has the details:

* the UFS 3.1 root device (the blocker for booting iOS),
* the display (an AMOLED on DSI D-PHY),
* the touch (a Goodix on QUPv3 SPI),
* the keys (the PM8008),
* the USB stack (the SM8470 DWC3).

`tools/port-series.py` does the mechanical part of the port: it takes a
patch from the sweet series, renames the board identifiers, drops the
context lines that name something a not yet ported hardware patch adds, and
tells you which hunks still need hardware work.
