# PAC probe: does this phone run an arm64e kernel?

The iOS 27 chain is arm64e. UniXNU's `docs/porting/arm64e.md` gates that route
on three things this board has never had measured: FEAT_PAuth in the ID
registers, the five key registers writable at EL1, and `PACIA`/`AUTIA` changing
a pointer at EL1. The shim runs before XNU, so one `fastboot boot` answers all
three.

## Build and boot

```sh
PAC_PROBE=1 BOARD=mondrian shim/build.sh
fastboot boot shim/out/shim-boot.img
```

The image carries no payload on purpose: the probe halts with the result on the
panel. Power + volume-down goes back to fastboot (`fastboot set_active b` if the
slot was marked unbootable).

## Read the screen

The probe prints each step **before** taking it, so a reset still names the step
that killed it.

| Line | Meaning |
| --- | --- |
| `PAC: el=1 pfr0=...` | AArch64 at EL1; `pfr0` low nibbles are the EL0/EL1 support |
| `ISAR1=...` / `ISAR2=...` | the raw feature registers, for the record |
| `FEAT APA=.. API=.. GPA=.. GPI=..` | nonzero on all four means FEAT_PAuth with address and generic keys |
| `FEAT APA3=.. GPA3=..` | the ISAR2 fallback; either set is enough |
| `RESULT no FEAT_PAuth` | no PAC: the ceiling is iOS 18 (arm64), stop the arm64e plan |
| `PAC: writing the five key pairs at EL1 ...` then a reset | the hypervisor traps the key registers (`HCR_EL2.APK/API`); arm64e is not usable here |
| `KEY RB ok` | the keys read back; the hypervisor left them alone |
| `RESULT PACIA is a NOP` | the core claims PAuth but does not sign: unusable |
| `RESULT AUTIA did not restore` | signing happened but authentication does not round-trip |
| `RESULT OK arm64e-capable at EL1` | the kernel side of the gate passed; the EL0/dyld side is the next test |

## What it does to the machine

Writes `SCTLR_EL1` EnIA/EnIB/EnDA/EnDB, the five key pairs and one `PACIA` /
`AUTIA` pair, then halts. It runs before the loader, so nothing of the iOS 16
boot is touched, and it writes no storage.

## Limits

- Boot core only; the other seven cores are checked by the arm64e kernel when it
  brings up SMP. The SM8475 clusters are the same ARMv9 generation.
- EL0 is not tested here: dyld is the first EL0 consumer, in phase 2.
- A reset is a result, not a failure: photograph the last line.
