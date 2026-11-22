#!/usr/bin/env python3
"""Map where the non-placeholder pixels are on a card surface dump.

The switcher card's surface is mostly one placeholder colour (magenta or
black); the drawn part is a sliver. The bounding box and the row histogram say
whether the app drew nothing, drew at the wrong scale (a corner), or drew
faint text across the surface -- three different bugs.

Usage: card-surface-map.py FILE [PLACEHOLDER]
"""
import os
import sys


def main(path, placeholder):
    base = os.path.basename(path)
    parts = base[:-len(".bgra")].split("-")
    width, height = (int(v) for v in parts[-3].split("x"))
    stride = int(parts[-2])
    data = open(path, "rb").read()
    if len(data) < stride * height:
        sys.exit("%s: short" % base)
    minx, miny, maxx, maxy = width, height, -1, -1
    rows = []
    total = 0
    for y in range(height):
        line = data[y * stride:y * stride + width * 4]
        count = 0
        first = last = -1
        for x in range(width):
            b, g, r = line[4 * x], line[4 * x + 1], line[4 * x + 2]
            if abs(b - placeholder[0]) + abs(g - placeholder[1]) + \
                    abs(r - placeholder[2]) > 40:
                count += 1
                if first < 0:
                    first = x
                last = x
        total += count
        rows.append((count, first, last))
        if count:
            minx = min(minx, first)
            maxx = max(maxx, last)
            miny = min(miny, y)
            maxy = max(maxy, y)
    print("%s: %dx%d, %d non-placeholder (%.2f%%), box x %d..%d y %d..%d"
          % (base, width, height, total, 100.0 * total / (width * height),
             minx, maxx, miny, maxy))
    step = max(1, height // 40)
    for y in range(0, height, step):
        chunk = rows[y:y + step]
        count = sum(c for c, _, _ in chunk)
        width_span = max((l - f + 1) for c, f, l in chunk if c) if count else 0
        print("  y %4d-%4d: %5d px, %3d wide" % (y, y + step - 1, count, width_span))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: card-surface-map.py FILE [PLACEHOLDER]")
    colour = (255, 0, 255)
    if len(sys.argv) > 2:
        colour = tuple(int(v) for v in sys.argv[2].split(","))
    main(sys.argv[1], colour)
