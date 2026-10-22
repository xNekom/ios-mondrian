---
name: qualcomm-device-tree
description: Read and audit a Qualcomm device tree (live DTB pulled from the phone, or upstream dtsi) for the nodes this port needs: UFS host, GCC clocks, reserved-memory carve-outs, the ABL splash framebuffer and the panel. Use when filling tools/boards.py, checking an address or interrupt before building an image, or when the shim and the device disagree.
---

# Reading a Qualcomm device tree

The real DTB is **reference data**, not a build input: XNU consumes the Apple
Device Tree that `tools/mkadt.py` synthesises. The job here is to get numbers
out of the real tree correctly and into `tools/boards.py` + `shim/board.h`.

## Get the live tree, not the vendor dtsi

The vendor sources (MiCode `kernel_devicetree`, branch `mondrian-s-oss`) are
what the phone probably runs; the live tree is what it *does* run. The
bootloader patches nodes at boot, so the two differ, sometimes in the values
that matter (`/chosen`, reserved-memory placement, clock rates).

```sh
# live tree, from a recovery that exposes /proc/device-tree
adb pull /proc/device-tree /private/tmp/mondrian-dt
tools/dtdump.py <tree-or-dtb> --build ...        # if it has to be rebuilt
tools/dtdump.py mondrian.dtb                     # whole tree
tools/dtdump.py mondrian.dtb --find ufs          # matching nodes only
tools/dtdump.py mondrian.dtb --prop reg          # one property, all nodes
```

The shim also prints the tree it was handed at boot; when shim output and
`dtdump.py` output disagree, the shim is the one that ran.

## Nodes that matter on mondrian

| node | why |
|------|-----|
| `ufshc@1d84000` | UFS host: `reg` base, `interrupts`, clocks. Confirms `0x1d84000` |
| `/reserved-memory` | ~38 carve-outs. Anything here is *not* free RAM; overlapping one corrupts firmware or the hypervisor |
| `cont_splash_region` | the ABL's linear framebuffer, `0xB8000000` + `0x2B00000`. This is the current display path |
| `qcom,mdss_mdp@ae00000` | display controller. Not used while the splash buffer is alive |
| panel node (`mdss_dsi_m11a_42_02_0a_dsc_cmd`) | timings/format; only needed if MDSS/DSI is ever driven |
| `gcc` / clock controllers | the UFS clock branch (`0x870`) had to be enabled by hand |
| TLMM, SPMI/PMIC | touch, buttons, battery: not started |

## Traps

- **Cell counts.** `reg` is meaningless without the parent's `#address-cells`
  and `#size-cells`. A 2/2 parent gives `<addr_hi addr_lo size_hi size_lo>`;
  reading it as 1/1 halves the addresses and looks plausible.
- **Interrupt numbering.** DT `interrupts` are GIC SPIs counted from 0; XNU
  INTIDs are SPI + 32. Copy the DT number into XNU and the handler never
  runs, with no error anywhere.
- **`cont_splash_region` vs reserved-memory.** The splash buffer is memory the
  ABL still scans out from. It must be skipped by the VM allocator (patch
  `0083`) *and* described in the ADT (`mondrian-fbcon`) so the console can map
  it. Describing it in one place only is the bug that shows up as a screen
  full of noise.
- **Overlap by arithmetic.** Check carve-outs by interval overlap against the
  kernel window (`0xB0000000` + `0x46000000`), not by name. Two carve-outs can
  share a page boundary.
- **Provisional values.** A number marked TODO in `tools/boards.py` is a guess.
  `mkadt.py` / `mkpayload.py` refuse it; `--allow-provisional` exists so the
  refusal is never bypassed by accident.
- **Clock names vs rates.** The DT gives a provider and an index, not a rate.
  The rate comes from the driver or from a register read on the device; say
  which one you used.

## Verification loop

1. `dtdump.py --find <node> --prop reg` gives the address.
2. Put it in `tools/boards.py` **and** `shim/board.h`.
3. Build the ADT and dump it (`tools/mkadt.py OUT.adt --dump`) to see what XNU
   will be told.
4. Boot the shim and compare what it prints with what the tree said.
5. Only then spend the change in a kernel patch.
