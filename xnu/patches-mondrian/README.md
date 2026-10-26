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
| `0001`–`0002` | the machine config for SM8475 (ARMv9.0, 16 KiB pages, GICv3 with eight redistributors, no PAC) and `config/MASTER.arm64.mondrian` |
| `0003`–`0055` | the generic half of the sweet series: RAM disk root, mockfs, AMFI, HFS+, BearSSL, the console, the crash log, the HID services, the SMP and the iPhone identity |
| `0056`–`0062` | the page-size work (commpage, zone map VA, bootstrap VA zone, no physical timer write, framebuffer alias reservation) and the first UFS 3.1 root device (`0059`); `0058` went away with the 4 KiB software page size |
| `0063`–`0069` | boot diagnostics and the interrupt path: `bsd_init` trail, console beacon, EL1 timer interrupt |
| `0070`–`0082`, `0086`, `0090`–`0114` | the UFS 3.1 root device, its wake sequence, the write path (`0090`), the task name in an unclassified abort (`0091`), the console's 64-bit clear (`0092`), bounded key-store calls (`0093`), the duplicate-surface lookup backboardd needs (`0094`), the userland sampler (`0095`), persistent logging with post-root startup and readback verification (`0096`–`0097`), the iOS swap path and `/private/var/vm` (`0098`), the dump's comma-separated term list (`0099`), the log/sampler paced by the UFS write path instead of dead timeouts (`0100`–`0101`), the one-shot detailed sampler dump (`0102`), the writer woken by console output (`0103`), the dump's six-line tails (`0104`), the console tee at the funnel point (`0105`), the opt-in personas/display diagnostics (`0106`), the lost-wakeup/exit-log fix (`0107`), the `AMFI` dyld-policy answer (`0108`), the target-aware detailed-sample trigger (`0109`), timer/GIC register snapshots (`0110`), the CNTV IMASK correction (`0111`), per-daemon injection modes (`0112`), the sampler kept out of the console and UFS paths (`0113`) and the display mode plus empty `IOAcceleratorES` that let CoreAnimation fall back to its software renderer (`0114`) |
| `0083`–`0085` | panel memory reservation, colour-bar self-test, IOSurface/IOMobileFramebuffer presentation |
| `0087`–`0089` | GIC remap after the VM takes over, `VFS_ROOT` errno before the panic, unsealed root accepted |

`0085` is the IOSurface + IOMobileFramebuffer pair. Each patch's symptom and
the trap behind it are in `NOTES.md`.

## Applying it

```
git clone --depth 1 --branch xnu-8796.141.3 \
    https://github.com/apple-oss-distributions/xnu.git xnu8796
tools/apply-series.py xnu8796 --series xnu/patches-mondrian --machine MONDRIAN
```

The CI **skips** a patch that does not apply and still reports success, so run
the command above (or `tools/check-patches.sh`) before pushing. It reports
113/113 for the current series. Two traps it catches: `git apply` rejects a hunk
that ends with added lines and no trailing context, and a patch touching a
staged source (HFS, BearSSL, libpthread) only applies after its staging script
ran. A *cancelled* job is reported as `failure` too.

`tools/validate-repo.py` is stricter than `git apply`, and three of its
findings on this series are known and harmless: the prose preamble of `0087`
(its diff starts further down, which `git apply` accepts) and a hunk count in
`0060`. All 111 patches apply with `git apply`; CI validates the kernel build.

## What is still missing

The patches that talk to the sweet phone's hardware. They are listed in
`HARDWARE_PATCHES` of `tools/port-series.py`; `docs/MONDIAN_PORT.md` has the
work items:

* the touch (a Goodix on QUPv3 SPI),
* the kernel-side keys and the dual-boot slot switch,
* the USB stack (the SM8475 DWC3), which is what would make the log readable
  without booting the viewer shim.

`tools/port-series.py` does the mechanical part of a port: it takes a patch from
the sweet series, renames the board identifiers, drops the context lines that
name something a not-yet-ported patch adds, and lists the hunks that need
hardware work.
