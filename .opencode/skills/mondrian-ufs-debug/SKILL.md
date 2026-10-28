---
name: mondrian-ufs-debug
description: Work the mondrian UFS and boot path. Use when a boot stops before the UFS root, when changing bsd/dev/mondrian_ufs.c, when a UPIU/OCS/sense value needs decoding, or when deciding the next storage experiment.
---

# mondrian UFS and the boot path

The UFS path works end to end: host takeover, NOP, LU wake, GPT, HFS+ mount
and `launchd`. A boot that stops before the ring is written is almost never a
UFS bug. Check the three boot traps first.

## A boot that leaves no log

1. **Shim.** The full shim runs `test_gic()` before the jump, storms and never
   starts the kernel. `nm shim/out/shim.elf | grep test_gic` must be empty;
   `tools/phone-deploy.sh` builds with `SMALL_SHIM=1`.
2. **vtimer.** `fiq_context_init()` clears IMASK; `0173` writes `CNTV_TVAL`
   first. Without it the level-sensitive PPI re-enters for ever and the boot
   never reaches the UFS probe.
3. **Ring.** `0174` arms the writer at the end of the UFS probe, before
   `vfs_mountroot`, so a failed mount leaves the error on disk. Read it from
   recovery (verify `userdata` is not mounted):

   ```sh
   bytes=$(adb shell blockdev --getsize64 /dev/block/by-name/userdata | tr -d '\r')
   skip=$((bytes / 4096 - 1025))
   adb shell "dd if=/dev/block/by-name/userdata of=/tmp/mondrian-log.raw bs=4096 skip=$skip count=1025"
   adb pull /tmp/mondrian-log.raw mondrian-log.raw
   tools/decode-mondrian-log.py mondrian-log.raw
   ```

4. **Screen.** `mondrianfb_noconsole=1`: the panel keeps the last frame, so a
   photo can be an earlier boot. The ring is the truth. `mondrianstop=N` halts
   at early mark N with IRQs masked; `0174` extends the marks through
   `bsd_init` and `vfs_mountroot`.

## Established facts

| fact | value |
|------|-------|
| host | `ufshc@1d84000`, mapped, clock on |
| registers after takeover | `hce 0x1 hcs 0x10f cap 0x1587031f ver 0x300` |
| DMA | 128 KiB contiguous at a known physical address (see `su.dma_pa`) |
| works | NOP OUT/IN, QUERY, TUR, START STOP UNIT, GPT read/write, HFS+ mount |
| wake | `bCurrentPowerMode 0x33` -> START STOP UNIT active on LUN `0xd0` -> `0x11` |
| `kmem_alloc_contig` | 256 pages never returns; keep requests <= ~128 KiB |

Values: `0x11` = UFS_ACTIVE_PWR_MODE, `0x33` = PowerDown, `0x22` = Idle.

## Register and UPIU constants in the driver

`REG_*` in `bsd/dev/mondrian_ufs.c` follow the UFSHCI layout: `IS 0x20`,
`IE 0x24`, `HCS 0x30`, `HCE 0x34`, `UTRLBA 0x50`, `UTRLDBR 0x58`,
`UTRLCLR 0x5c`, `UTRLRSR 0x60`, `UTRLCNR 0x64`, `UTRIACR 0x4c`.

- UPIU types: `0x01` command request, `0x21` response, `0x16` query request,
  `0x36` query response, `0x20`/`0x30` NOP out/in.
- Query opcodes (byte 12): READ_DESC `0x01`, WRITE_DESC `0x02`, READ_ATTR
  `0x03`, WRITE_ATTR `0x04`, READ_FLAG `0x05`, SET_FLAG `0x06`, CLEAR_FLAG
  `0x07`. Byte 5 is the function: `0x01` read, `0x81` write.
- `bCurrentPowerMode` = idn `0x02`; `fDeviceInit` = idn `0x01`.
- Wake: START STOP UNIT, CDB `{0x1b, 0, 0, 0, 0x10, 0}`, on the device
  well-known LUN `0xd0` (UPIU LUN byte at offset 2).

## The clock rule

The timer now ticks and `ufs_calibrate_spins()` prints the measured
spins/ms. Keep the waits spin-counted anyway: `delay()` and
`mach_absolute_time()` were broken when this path was written, and a wait
that never completes must print `hcs/is/dbr` and clear `UTRLCLR`, not hang.

## Writes and the ring

`0090` adds WRITE(10), SYNCHRONIZE CACHE and the write path; `DKIOCISWRITABLE`
must agree or HFS disables writes. The persistent ring sits in the last
4 MiB + 4 KiB of `userdata`, far behind the HFS image. A failed mount can zero
an HFS+ B-tree node; if the ring says `hfs_swap_BTNode: offset #0 invalid`,
read volume block 2178 from recovery before blaming the driver and see the
restore procedure in `NOTES.md`.

## References, in order of usefulness

1. sweet's driver: the same file in `xnu/patches-mondrian/` early patches - it
   works on real hardware.
2. `/private/tmp/unixnu/drivers/NativeUfs/` - SM8550, same family, does the
   wake sequence.
3. Linux `drivers/scsi/ufs/ufshcd.c` - `ufshcd_set_dev_pwr_mode`,
   `ufshcd_query_flag`, `ufshcd_compl_one_cqe`. The authority on encodings
   (query struct at offset 12, value at 20..23, big endian).

Add diagnostics for the *next* question to the same build when they are free;
each boot costs a flash.
