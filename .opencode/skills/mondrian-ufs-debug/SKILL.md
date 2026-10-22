---
name: mondrian-ufs-debug
description: Work the mondrian UFS bring-up, the current boot blocker. Use when a boot stops before "device_add_rd0", when changing bsd/dev/mondrian_ufs.c, when a UPIU/OCS/sense value needs decoding, or when deciding the next storage experiment.
---

# mondrian UFS

The kernel boots to BSD root mount and stops here: the UFS logical unit never
answers, so `IOFindBSDRoot` has nothing to mount. Everything below is measured
on the device, not copied from a spec.

## Established facts

| fact | value |
|------|-------|
| host | `ufshc@1d84000`, mapped, clock on |
| registers after takeover | `hce 0x1 hcs 0x10f cap 0x1587031f ver 0x300` |
| DMA | 128 KiB contiguous at a known physical address (see `su.dma_pa`) |
| works | NOP OUT / NOP IN, QUERY READ ATTRIBUTE, QUERY READ FLAG |
| does not work | the LU answers no SCSI command; `bCurrentPowerMode 0x33` (PowerDown) |
| previous TUR sense | `2/04/02` (not ready, becoming ready) |
| `QUERY SET FLAG fDeviceInit` | returned `response 0xff` (general failure) with the encoding used then |
| `kmem_alloc_contig` | 256 pages never returns; keep requests <= ~128 KiB |

Values: `0x11` = UFS_ACTIVE_PWR_MODE, `0x33` = PowerDown, `0x22` = Idle.

## Register and UPIU constants in the driver

`REG_*` in `bsd/dev/mondrian_ufs.c` follow the UFSHCI layout: `IS 0x20`,
`IE 0x24`, `HCS 0x30`, `HCE 0x34`, `UTRLBA 0x50`, `UTRLDBR 0x58`,
`UTRLCLR 0x5c`, `UTRLRSR 0x60`, `UTRLCNR 0x64`, `UTRIACR 0x4c`.

- UPIU types: `0x01` command request, `0x21` response, `0x16` query request,
  `0x36` query response, `0x20`/`0x30` NOP out/in.
- Query opcodes (byte 12 of the query UPIU): READ_DESC `0x01`, WRITE_DESC
  `0x02`, READ_ATTR `0x03`, WRITE_ATTR `0x04`, READ_FLAG `0x05`, SET_FLAG
  `0x06`, CLEAR_FLAG `0x07`. Byte 5 is the function: `0x01` read, `0x81`
  write.
- Attribute `bCurrentPowerMode` = idn `0x02`; flag `fDeviceInit` = idn `0x01`.
- Wake command: START STOP UNIT, CDB `{0x1b, 0, 0, 0, 0x10, 0}`. Byte 4 holds
  the power condition modifier in the high nibble, so `0x10` = active. Sent to
  the device well-known LUN `0xd0`, which goes in the UPIU LUN byte (offset 2).

## The clock rule

The 0082 boot froze at `scsi 0x1b sent, waiting` with no timeout line. That is
the first place in the whole boot that used `mach_absolute_time()` and
`delay()`, and the timer interrupt has never been observed on this board. So:

- **every wait counts CPU spins**, calibrated once (`ufs_calibrate_spins()`,
  which also prints ticks-per-spin so the log says whether the counter moves);
- **a wake that never completes is not fatal**: print the host state, clear the
  doorbell with `UTRLCLR`, and let TEST UNIT READY decide whether the wake
  worked;
- never reintroduce `delay()`/`mach_absolute_time()` on this path until a boot
  has proved the timer.

## Read-only promise

`mondrian_ufs_write()` returns `EROFS`. The driver issues only NOP, QUERY,
TEST UNIT READY and START STOP UNIT, none of which touch the medium. GPT
corruption becomes possible the moment writes are enabled, so:

1. `tools/backup-gpt.sh` first (fastboot partition table + raw primary/backup
   GPT via adb), verify `EFI PART`;
2. then port sweet `0030` (the write path), then `0047` (the persistent
   `SWEETLOG` ring plus `tools/ios-log-pull.sh`), because a userland panic will
   only be visible through that ring.

## References, in order of usefulness

1. sweet's driver: the same file in `xnu/patches-mondrian/` early patches - it
   works on real hardware.
2. `/private/tmp/unixnu/drivers/NativeUfs/` - SM8550, same family, does the
   wake sequence.
3. Linux `drivers/scsi/ufs/ufshcd.c` - `ufshcd_set_dev_pwr_mode`,
   `ufshcd_query_flag`, `ufshcd_compl_one_cqe`. The authority on encodings
   (query struct at offset 12, value at 20..23, big endian).

## Next experiments, in order

1. Does the counter move? The calibration line answers it. If not, fix the
   timebase before any other work: the whole kernel depends on it.
2. Does the LU answer TUR *before* any wake attempt? The new driver prints
   this baseline. If TUR succeeds, the wake sequence is unnecessary.
3. Does `fDeviceInit` read 0 or 1? 0 means the device finished initialising
   and the flag write is not needed; 1 means the encoding of SET FLAG has to be
   fixed (length/value fields, function `0x81`).
4. If START STOP UNIT still never completes: decode the printed `hcs/is/dbr`
   and the UTRD dwords. `dw2` still holding `0xf` means the host never read the
   descriptor; a real OCS with a response UPIU means the device answered
   something unexpected.
5. Only after the LU answers: GPT parse, then `userdata`, then the write path.

Add diagnostics for the *next* question to the same build when they are free;
each boot costs a flash.
