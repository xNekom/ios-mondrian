"""Crop a region out of a ring capture and blow it up, to look at one control.

The ring's PNGs are RGB8 with filter 0 on every row (tools/usb-ring.py writes
them), so a crop needs zlib and nothing else. Nearest-neighbour is enough: the
question is "is the knob there", not what it looks like at 300 dpi.

Usage: png-crop.py IN.png OUT.png X0 Y0 W H [SCALE]
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
        start = y * stride
        if raw[start] != 0:
            raise SystemExit("row %d carries filter %d" % (y, raw[start]))
        rows.append(raw[start + 1:start + stride])
    return width, height, rows


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data +
            struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def main():
    if len(sys.argv) < 7:
        raise SystemExit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    x0, y0, cw, ch = (int(v) for v in sys.argv[3:7])
    scale = int(sys.argv[7]) if len(sys.argv) > 7 else 4
    width, height, rows = load(src)
    x1, y1 = min(x0 + cw, width), min(y0 + ch, height)
    out_rows = []
    for y in range(max(y0, 0), y1):
        line = rows[y][max(x0, 0) * 3:x1 * 3]
        wide = b"".join(line[x * 3:x * 3 + 3] * scale
                        for x in range(x1 - max(x0, 0)))
        for _ in range(scale):
            out_rows.append(wide)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB",
                                      (x1 - max(x0, 0)) * scale,
                                      len(out_rows), 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(
        b"".join(b"\x00" + row for row in out_rows), 6))
    png += chunk(b"IEND", b"")
    open(dst, "wb").write(png)
    print("%s %dx%d from %s at %d,%d x%d"
          % (dst, (x1 - max(x0, 0)) * scale, len(out_rows), src,
             max(x0, 0), max(y0, 0), scale))


if __name__ == "__main__":
    main()
