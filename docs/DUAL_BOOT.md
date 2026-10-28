# Dual boot: iOS on `userdata` and a temporary Android

The iOS root lives in a 16 GiB HFS+ volume at the start of the single
`userdata` partition (37, 4K blocks `0x2f8a00..0x3adeffa`). Android needs a
`userdata` filesystem of its own, so a capture boot splits the partition in
two without moving the HFS volume:

| partition | name | first block | last block | size |
| --- | --- | --- | --- | --- |
| 37 | `iosroot` | `0x2f8a00` | `0x6f91ff` | 16 GiB + 8 MiB |
| 38 | `userdata` | `0x6f9200` | `0x3adeffa` | 207.6 GiB |
| 37 | `userdata` (original) | `0x2f8a00` | `0x3adeffa` | 223.6 GiB |

The extra 8 MiB on `iosroot` hold the touch firmware blob and the persistent
console ring; the HFS volume itself is still 16 GiB (`totalBlocks 0x400000`).
Both work on 4K sectors.

## Before touching the GPT

1. A verified `gzip` image of the 16 GiB volume, the GPT, and the **last
   8 MiB of `userdata`** (`dd bs=4096 skip=<nblocks-2048> count=2048`). The
   last 8 MiB contain the 64-block `BERLIN` touch firmware blob at offset
   `end-1089` and the `MONDLOG` ring at `end-1024`; they are outside the HFS
   filesystem and a normal volume backup does not cover them.
2. Check the HFS volume header (`sig 0x4858`, `blockSize 4096`) and set the
   attributes to `0x80000100` (journaled bit clear, unmounted bit set) so a
   later mount does not replay a stale transaction:
   `printf`/`dd` the 4 bytes at byte `1024+4` of the partition's first block.

## Split

```sh
sgdisk /dev/block/sda --delete=37 \
  --new=37:0x2f8a00:0x6f91ff --typecode=37:8300 --change-name=37:iosroot \
  --new=38:0x6f9200:0x3adeffa --typecode=38:A03A --change-name=38:userdata
```

Copy the tail **before** Android formats the new `userdata` (the old tail is
inside it): 1089 blocks from the old blob base `0x3adeffa-1025-64+1` to the
new blob base `0x6f91ff-1025-64+1`, with `dd bs=4096 skip=... seek=...
count=1089 conv=notrunc` on `/dev/block/sda`. Verify the two md5s and that
`MONDLOG` lands at the new ring base.

Android boots from the current `_b` slot (Lineage userdebug in this unit),
formats the new `userdata` and runs. Clear the `misc` BCB first: 32 zero bytes
at block 0 (`dd if=/dev/zero of=/dev/block/by-name/misc bs=32 count=1
conv=notrunc`), or the reset thread's `boot-fastboot` sends the next boot to
fastbootd.

## Capture, then restore

Android's Lineage kernel has no `debugfs` and no `/dev/mem`, so the GPUCC
registers are not readable; the useful capture is the vendor firmware in
`/vendor/firmware` (`gmu_gen70000.bin`, `a730_sqe.fw`, `a730_zap.*`), the
kernel config, the kgsl `dmesg`, the OPP list and the live DT. Do not expect
clock/regulator summaries from debugfs.

Restore the original layout:

```sh
sgdisk /dev/block/sda --delete=37 --delete=38 \
  --new=37:0x2f8a00:0x3adeffa --typecode=37:A03A --change-name=37:userdata
dd if=tail8m.bin of=/dev/block/sda bs=4096 seek=$((0x3adeffa+1-2048)) \
  conv=notrunc
```

Then verify, in this order: the ring header `MONDLOG` at `end-1024`, the blob
`BERLIN` at `end-1089`, the volume header `0x4858` with attributes
`0x80000100`, and a valid extent B-tree node at volume block 2178. Clear the
`misc` BCB again and boot the iOS image with the default board cmdline
(`rd=ufsroot0`, no `ufsroot` argument). The lock screen is the proof.

If the volume was mounted read-write after a hard reset, its attributes come
back as `0x80004000` (mounted, journal off); rewrite `0x80000100` before the
next boot. The HFS data itself is valid: the write count increases and the
B-tree nodes stay valid, as measured on 2026-10-28.

## Automatic capture

`tools/mondrian-boot-log.sh IMAGE` does the cycle: it puts the phone in the
bootloader, boots the image, waits for the `mondrianreset` return, boots the
recovery, reads the last 1025 blocks of `userdata` (or `ROOT_PART=iosroot`),
decodes them and, with `--ios IMAGE`, boots iOS again. Build the test image
with `mondrianreset=45`; the script waits up to `--reset` plus 120 s. It
starts from fastboot or adb, never from iOS: hold power + volume down first.
`WORK`, `RECOVERY`, `IOS_IMAGE`, `SERIAL` and `ROOT_PART` override the
defaults.
