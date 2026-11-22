"""Height of a Control Center capsule's bright fill, from two ring captures.

The ring's PNGs are RGB8 with filter 0 on every row (tools/usb-ring.py writes
them), so they decode with zlib alone. A capsule's fill is the bright band at
the bottom; its top edge is the value the slider shows.

Usage: python tools/png-capsule-fill.py OUT.png X0 X1 Y0 Y1 [OUT2.png ...]
"""

import struct
import sys
import zlib


def load(path):
    data = open(path, "rb").read()
    at = 8
    width = height = 0
    idat = b""
    while at < len(data):
        length = struct.unpack_from(">I", data, at)[0]
        kind = data[at + 4:at + 8]
        body = data[at + 8:at + 8 + length]
        if kind == b"IHDR":
            width, height = struct.unpack_from(">II", body, 0)
        elif kind == b"IDAT":
            idat += body
        at += 12 + length
    raw = zlib.decompress(idat)
    stride = width * 3 + 1
    rows = []
    for y in range(height):
        line = raw[y * stride:(y + 1) * stride]
        if line[0] != 0:
            raise SystemExit(f"{path}: filter {line[0]} is not 0")
        rows.append(line[1:])
    return width, height, rows


def fill_top(rows, x0, x1, y0, y1, threshold=200):
    """Topmost row in the box whose row is mostly bright, or y1 if none."""
    for y in range(y0, y1):
        line = rows[y]
        bright = sum(1 for x in range(x0, x1, 4)
                     if line[x * 3] > threshold and
                     line[x * 3 + 1] > threshold and
                     line[x * 3 + 2] > threshold)
        if bright * 4 >= (x1 - x0) * 3 // 4:
            return y
    return y1


def main():
    if len(sys.argv) < 6:
        raise SystemExit(__doc__)
    x0, x1, y0, y1 = (int(v) for v in sys.argv[2:6])
    for path in sys.argv[1::1]:
        if not path.endswith(".png"):
            continue
        _, height, rows = load(path)
        top = fill_top(rows, x0, x1, y0, min(y1, height))
        print(f"{path}: fill from row {top} of {height}")


if __name__ == "__main__":
    main()
