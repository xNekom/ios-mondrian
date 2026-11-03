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
| `0070`–`0082`, `0086`, `0090`–`0116` | the UFS 3.1 root device, its wake sequence, the write path (`0090`), the task name in an unclassified abort (`0091`), the console's 64-bit clear (`0092`), bounded key-store calls (`0093`), the duplicate-surface lookup backboardd needs (`0094`), the userland sampler (`0095`), persistent logging with post-root startup and readback verification (`0096`–`0097`), the iOS swap path and `/private/var/vm` (`0098`), the dump's comma-separated term list (`0099`), the log/sampler paced by the UFS write path instead of dead timeouts (`0100`–`0101`), the one-shot detailed sampler dump (`0102`), the writer woken by console output (`0103`), the dump's six-line tails (`0104`), the console tee at the funnel point (`0105`), the opt-in personas/display diagnostics (`0106`), the lost-wakeup/exit-log fix (`0107`), the `AMFI` dyld-policy answer (`0108`), the target-aware detailed-sample trigger (`0109`), timer/GIC register snapshots (`0110`), the CNTV IMASK correction (`0111`), per-daemon injection modes (`0112`), the sampler kept out of the console and UFS paths (`0113`), the display mode plus empty `IOAcceleratorES` that let CoreAnimation fall back to its software renderer (`0114`), the panel written through the console alias with the console paused without unmapping it (`0115`), and the vtimer PPI fix (active state, Group 1 modifier) with the timer/interrupt diagnostics (`0116`) |
| `0083`–`0085` | panel memory reservation, IOSurface/IOMobileFramebuffer presentation (`0084`'s colour-bar self-test is off since `0208`) |
| `0087`–`0089` | GIC remap after the VM takes over, `VFS_ROOT` errno before the panic, unsealed root accepted |
| `0117`–`0180` | the hardware bring-up after the display: the Goodix touch (TLMM, GENI SPI, 220 KB firmware, vsync reports), the GPU probe (GMU SMMU and firmware, HFI power tables, GX, the ARC votes), the `0173` timer arm, the boot bisect marks, the canvas CFData types, and the cmd-db/RSC mapping cache |
| `0181`–`0184` | the CP path and its SMMU context (`0181`), the `MondrianGPU` user client (`0182`), the surface wrap refusal (`0183`) and the inert `mondrian_gpu_uc_*` fallback when the local CP profile is absent (`0184`) |
| `0185`–`0202` | the submission path: the CP's SMMU ASID invalidate when the tables change (`0185`), diagnostics that survive a wedged CP (`0186`–`0188`), the GPU left stopped after a missed fence (`0191`), the draw-state expansion behind `gpunostate=1` (`0193`, `0195`), the doorbell written from its own thread and then defaulted back to inline (`0196`, `0197`), `gen7_start` + `CP_ME_INIT` behind `gpuinit=1`/`gpuinit=2` (`0198`), and the diagnostics that answer the wedged draw: `CB_FAR`/syndrome in the dump (`0199`), the latched-SMMU-fault clear plus a page-table walk for the faulting address (`0200`), and kgsl's IFPC/IB1LIST bracket, which is what lets the first draw fence (`0201`, behind `gpunomark=1`), and the submit-step markers plus `RBBM_STATUS` that say where a boot died (`0202`) |
| `0203`–`0213` | what made the first draw complete and then stay healthy: the bracket off by default (`0203`), kgsl's ring wrap with backpressure (`0204`), the `uc enter` marker (`0205`), a 512 KiB CP page-table region (`0206`), IOVA range reuse (`0207`), no colour bars over the boot logo (`0208`), the digitizer event marked display integrated so backboardd delivers it (`0209`), the kernel log painted on the panel with a page scroll (`0210`), GPU buffers allowed above the lowest 4 GiB (`0211`), a console painter the log cannot outrun (`0212`), and that painting moved off the printf path into the log thread (`0213`) |

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
207/207 for the current series. Two traps it catches: `git apply` rejects a hunk
that ends with added lines and no trailing context, and a patch touching a
staged source (HFS, BearSSL, libpthread) only applies after its staging script
ran; `NO_STAGE=1` makes `0036` fail for that reason alone. A *cancelled* job is
reported as `failure` too.

`tools/validate-repo.py` is stricter than `git apply`, and three of its
findings on this series are known and harmless: the prose preamble of `0087`
(its diff starts further down, which `git apply` accepts) and a hunk count in
`0060`. All 207 patches apply with `git apply`; CI validates the kernel build.

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
