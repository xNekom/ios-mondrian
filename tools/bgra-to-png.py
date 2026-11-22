#!/usr/bin/env python3
"""Turn a raw BGRA surface a bridge dump wrote into PNGs to look at.

The bridge writes /private/var/mobile/Library/Preferences/
mondrian-pic-<w>x<h>-<row>-<n>.bgra, four bytes a pixel, stride <row>. The file
name carries the geometry, so the surface's own header is not needed.

Two pictures come out: NAME.png keeps the alpha the layer will ship, and
NAME-rgb.png forces alpha to 255, so a knob whose pixels are right but whose
alpha is zero cannot hide behind the checkerboard of a viewer.

Usage: bgra-to-png.py FILE [FILE...]
"""
import os
import struct
import sys
import zlib


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data +
            struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + row for row in rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as out:
        out.write(png)


def convert(path):
    base = os.path.basename(path)
    parts = base[:-len(".bgra")].split("-")
    width, height = (int(v) for v in parts[-3].split("x"))
    stride = int(parts[-2])
    data = open(path, "rb").read()
    if len(data) < stride * height:
        print("%s: %d bytes, short of %d" % (base, len(data), stride * height))
        return
    opaque, kept = [], []
    for y in range(height):
        row = data[y * stride:y * stride + stride]
        kept.append(b"".join(row[x * 4 + 2:x * 4 + 3] + row[x * 4 + 1:x * 4 + 2] +
                             row[x * 4:x * 4 + 1] + row[x * 4 + 3:x * 4 + 4]
                             for x in range(width)))
        opaque.append(b"".join(row[x * 4 + 2:x * 4 + 3] + row[x * 4 + 1:x * 4 + 2] +
                               row[x * 4:x * 4 + 1] + b"\xff"
                               for x in range(width)))
    stem = path[:-len(".bgra")]
    write_png(stem + ".png", width, height, kept)
    write_png(stem + "-rgb.png", width, height, opaque)
    nonzero = sum(1 for b in data[0:stride * height] if b)
    print("%s: %dx%d stride %d, %d nonzero bytes, alpha0 %d/%d"
          % (base, width, height, stride, nonzero,
             sum(1 for y in range(height) for x in range(width)
                 if data[y * stride + x * 4 + 3] == 0), width * height))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: bgra-to-png.py FILE [FILE...]")
    for arg in sys.argv[1:]:
        convert(arg)
