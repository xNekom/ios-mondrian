#!/usr/bin/env python3
"""Convert a raw partition image to the Android sparse format.

  tools/mk-simg.py ROOT.img ROOT.simg

Needed because the mondrian bootloader reports max-download-size 768 MiB:
fastboot 37 refuses a bigger *raw* image with "Failed reading from
userdata" (it tries to resparse it, which makes it read the partition, and
the bootloader does not serve reads). A sparse image needs no resparsing:
fastboot sends it in chunks of the size given with -S, and the zero regions
cost nothing (CHUNK_TYPE_DONT_CARE), so the 16 GiB root transfers only the
11 GiB that hold data.

The format is the documented one (system/core/libsparse/sparse_format.h):
a 28-byte header, then chunks of 4096-byte blocks, either RAW, DONT_CARE
(all zeros) or FILL.
"""
import os
import struct
import sys

BLK = 4096
WINDOW = 1 << 20            # granularity of the zero/nonzero decision
MAX_BLOCKS = 16384          # 64 MiB per chunk: what fastboot and libsparse expect
HEADER = struct.Struct('<IHHHHIIII')
CHUNK = struct.Struct('<HHII')
MAGIC = 0xed26ff3a
RAW, DONT_CARE = 0xcac1, 0xcac3


def flush(out, windows):
    """Write one chunk for a run of windows of the same kind."""
    data = b''.join(w for _, w in windows)
    blocks = (len(data) + BLK - 1) // BLK
    if windows[0][0]:
        out.write(CHUNK.pack(DONT_CARE, 0, blocks, 12))
    else:
        out.write(CHUNK.pack(RAW, 0, blocks, 12 + blocks * BLK))
        out.write(data)
        out.write(b'\0' * (blocks * BLK - len(data)))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    src, dst = sys.argv[1], sys.argv[2]
    size = os.path.getsize(src)
    total_blks = (size + BLK - 1) // BLK

    with open(src, 'rb') as f, open(dst, 'wb') as out:
        out.write(HEADER.pack(MAGIC, 1, 0, 28, 12, BLK, total_blks, 0, 0))
        chunks = 0
        run = []
        while True:
            w = f.read(WINDOW)
            if not w:
                break
            zero = w.count(0) == len(w)
            if run and (run[0][0] != zero or len(run) * WINDOW >= MAX_BLOCKS * BLK):
                flush(out, run)
                chunks += 1
                run = []
            run.append((zero, w))
        if run:
            flush(out, run)
            chunks += 1
        out.seek(0)
        out.write(HEADER.pack(MAGIC, 1, 0, 28, 12, BLK, total_blks, chunks, 0))

    print(f'{src}: {size} bytes -> {dst} ({os.path.getsize(dst)} bytes, '
          f'{chunks} chunks)')


if __name__ == '__main__':
    main()
