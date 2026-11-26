# Bug Verification: Wi-Fi premap panic

- **Slug**: wifi-premap-io-map
- **Date**: 2026-11-27
- **Result**: verified (the premap panic is gone; a later, separate failure remains)

## Summary

`0486` removes the seventh `ml_io_map()` from the pin premap and derives
GPIO 82 from GPIO 80's window. A boot built with `0486` and the Wi-Fi args
(`mondrianwifi=1 mondrianwififw=1 mondrianwifidelay=0`) no longer panics in
`io_map()`: it reaches userland and the worker logs the W10 pads line with a
valid `sw` read (`sw=1/1`), then W6/W8/W9/W11/W15. The premap bug is fixed.

The same boot dies right after `W15 bypass rc=-1`, before the next flushed
line (`W15 bypass status=`). That is a new, separate failure of the
`mondrianwifibypass=1` diagnostic, not the premap panic.

## Checks Performed

1. Built `0486`, confirmed the image and kernel banners (`23:37:51`) and that
   the patch series applies (477/477).
2. Control boot with the same kernel and no Wi-Fi args: the ring answers with
   the new banner and `wifistage 0`; the image and shim handoff are good.
3. Wi-Fi boot: the live ring does not answer (the boot dies before the gadget
   is reachable), so the evidence is the flushed console read back with
   `prev` from the `boot_b` fallback.
4. Verified the compiled constants with `llvm-objdump`: the premap calls
   `ml_io_map(0x0f150000|0x0f15c000|0x0f160000|0x0f1cc000, 0x4000)`, and the
   worker reads `W10 pads ... sw=1/1`.

## Output Excerpts

```
PREV | MONDRIAN WIFI: W6 auto load start
PREV | MONDRIAN WIFI: W10 pads wlan=3c3/3 sw=1/1 perst=201/3 clkreq=7/0 wake=3/0 xo=1ac0/0 bt=1/0
...
PREV | MONDRIAN WIFI: W6 post-reset command=0x406
PREV | MONDRIAN WIFI: W11 smmu pre fsr=0x400 far=0x4025404 gfsr=0x0 fsynr=0x40d56
PREV | MONDRIAN WIFI: W15 start
PREV | MONDRIAN WIFI W2: readback mismatch off=0xc18 want=0x10000 got=0x20000
PREV | MONDRIAN WIFI: W15 bypass rc=-1
```

No `MONDRIAN PANIC` line appears in the flushed console.

## Residual Risks

- The boot still resets after W15; the panic reason is not in the flushed ring
  because the panic flush runs before the reason is printed. Skipping the W15
  diagnostic (`mondrianwifibypass=1`) is the next experiment, not a fix.
- The Wi-Fi boot's ring does not answer on the host during these attempts, so
  every result must come from `prev` plus a successful control boot, not from
  the live ring.

## Recommendation

Close this bug as verified. Open a new assessment for the W15 bypass reset
with the evidence above; the first remediation is to drop
`mondrianwifibypass=1` and reach the BHI doorbell (stage 17/18) without the
diagnostic.
