#!/usr/bin/env python3
"""Merge the ROM's split sparse pieces into one full-size image.

Each `super.img.N` is an Android sparse image of the *whole* super partition:
the blocks it does not carry are DONT_CARE chunks, so concatenating the pieces
(or concatenating their sparse streams) scrambles the layout. The correct merge
applies each piece's RAW and FILL chunks at their own block offsets into a
full-size output and leaves DONT_CARE blocks alone.

    tools/sparse-merge.py OUT PIECE [PIECE ...]

No device data is involved: ROM images only.
"""

import os
import struct
import sys

SPARSE_MAGIC = 0xED26FF3A
RAW = 0xCAC1
FILL = 0xCAC2
DONT_CARE = 0xCAC3
CRC32 = 0xCAC4


def merge(out_path, pieces, blk_sz, total_blks):
    total = blk_sz * total_blks
    out = open(out_path, "r+b" if os.path.exists(out_path) else "w+b")
    out.truncate(total)
    written = 0
    for path in pieces:
        f = open(path, "rb")
        hdr = f.read(28)
        magic, _maj, _min, file_hdr_sz, chunk_hdr_sz, blk, blks, chunks, _csum = \
            struct.unpack("<IHHHHIIII", hdr)
        if magic != SPARSE_MAGIC:
            raise SystemExit("%s: not a sparse image" % path)
        if blk != blk_sz or blks != total_blks:
            raise SystemExit("%s: geometry %u/%u differs from %u/%u"
                             % (path, blk, blks, blk_sz, total_blks))
        f.seek(file_hdr_sz)
        at = 0
        for _ in range(chunks):
            chdr = f.read(12)
            if len(chdr) < 12:
                raise SystemExit("%s: truncated chunk header" % path)
            ctype, _res, chunk_sz, total_sz = struct.unpack("<HHII", chdr)
            body = total_sz - chunk_hdr_sz
            if ctype == RAW:
                data = f.read(body)
                if len(data) != body:
                    raise SystemExit("%s: truncated raw chunk" % path)
                out.seek(at * blk_sz)
                out.write(data)
                written += len(data)
            elif ctype == FILL:
                value = f.read(4)
                out.seek(at * blk_sz)
                out.write(value * (chunk_sz * blk_sz // 4))
                written += chunk_sz * blk_sz
            elif ctype == DONT_CARE:
                pass
            elif ctype == CRC32:
                f.read(body)
            else:
                raise SystemExit("%s: unknown chunk type 0x%x" % (path, ctype))
            at += chunk_sz
        f.close()
    out.close()
    print("wrote %s: %u blocks of %u, %.1f MB of chunk data"
          % (out_path, total_blks, blk_sz, written / (1 << 20)))


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    out_path = sys.argv[1]
    pieces = sys.argv[2:]
    f = open(pieces[0], "rb")
    hdr = f.read(28)
    magic, _maj, _min, _fhs, _chs, blk, blks, chunks, _csum = \
        struct.unpack("<IHHHHIIII", hdr)
    f.close()
    if magic != SPARSE_MAGIC:
        raise SystemExit("%s: not a sparse image" % pieces[0])
    print("geometry from %s: %u blocks of %u, %u chunks"
          % (pieces[0], blks, blk, chunks))
    merge(out_path, pieces, blk, blks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
