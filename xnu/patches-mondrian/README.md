# The mondrian patch series

The XNU patch series for the **POCO F5 Pro / Redmi K60** (`mondrian`, Qualcomm
SM8475 / Snapdragon 8+ Gen 1). It is parallel to `xnu/patches/`, which stays the
working `sweet` series: different SoCs, and the patches are not
interchangeable.

The CI picks a series with the `board` input of `.github/workflows/xnu.yml`:

| board | series | machine config |
| --- | --- | --- |
| `sweet` (default) | `xnu/patches/` | `SWEET` |
| `mondrian` | `xnu/patches-mondrian/` | `MONDRIAN` |

## What is in here

| Patch | What |
| --- | --- |
| `0001`–`0002` | the machine config for SM8475 (ARMv9.0, 4 KiB pages, GICv3 with eight redistributors, no PAC) and `config/MASTER.arm64.mondrian` |
| `0003`–`0055` | the generic half of the sweet series: RAM disk root, mockfs, AMFI, HFS+, BearSSL, the console, the crash log, the HID services, the SMP and the iPhone identity |
| `0056`–`0062` | the 4 KiB page work (commpage, zone map VA, software page size, bootstrap VA zone, no physical timer write, framebuffer alias reservation); `0059` is the first UFS 3.1 root device |
| `0063`–`0069` | boot diagnostics and the interrupt path: `bsd_init` trail, console beacon, EL1 timer interrupt |
| `0070`–`0082`, `0086` | the UFS 3.1 root device and its wake sequence |
| `0083`–`0084` | panel memory kept off the free list, colour-bar self-test |
| `0087`–`0089` | GIC remap after the VM takes over, `VFS_ROOT` errno before the panic, unsealed root accepted |

`0085` (the IOSurface + IOMobileFramebuffer pair) lives on branch `display` and
is merged once the root mounts. Each patch's symptom and the trap behind it are
in `NOTES.md`.

## Applying it

```
git clone --depth 1 --branch xnu-8796.141.3 \
    https://github.com/apple-oss-distributions/xnu.git xnu8796
tools/apply-series.py xnu8796 --series xnu/patches-mondrian --machine MONDRIAN
```

The CI **skips** a patch that does not apply and still reports success, so run
the command above (or `tools/check-patches.sh`) before pushing. It reports
87/87 for the current series. Two traps it catches: `git apply` rejects a hunk
that ends with added lines and no trailing context, and a patch touching a
staged source (HFS, BearSSL, libpthread) only applies after its staging script
ran.

`tools/validate-repo.py` is stricter than `git apply`, and three of its
findings on this series are known and harmless: the numbering gap at `0085`
(the patch is on branch `display`), the prose preamble of `0087` (its diff
starts further down, which `git apply` accepts) and a hunk count in `0060`. All
87 patches apply with `git apply` and build in CI as they are.

## What is still missing

The patches that talk to the sweet phone's hardware. They are listed in
`HARDWARE_PATCHES` of `tools/port-series.py`; `docs/MONDIAN_PORT.md` has the
work items:

* writes for the UFS root device (reads work; the persistent console log needs
  the same write path),
* the display presentation driver (`0085`),
* the touch (a Goodix on QUPv3 SPI),
* the kernel-side keys and the dual-boot slot switch,
* the USB stack (the SM8475 DWC3).

`tools/port-series.py` does the mechanical part of a port: it takes a patch from
the sweet series, renames the board identifiers, drops the context lines that
name something a not-yet-ported patch adds, and lists the hunks that need
hardware work.
