#!/usr/bin/env python3
"""Say what the bytes of a card surface really contain.

The pass-through IOSurface a switcher card receives was dumped by the bridge
(`mondrian-card-WxH-ROW-N.bgra`). "Nonzero" is not an answer: the poisoned
canvas is a specific colour, and a real card is a photo of the app. This reads
the dump and reports the colour histogram's top entries, the centre pixel and
how much of the picture matches the magenta test the hook uses
(`B > 150`, `G < 90`, `R > 150`).

Usage: card-surface-stats.py FILE
"""
import collections
import os
import sys


def main(path):
    base = os.path.basename(path)
    parts = base[:-len(".bgra")].split("-")
    width, height = (int(v) for v in parts[-3].split("x"))
    stride = int(parts[-2])
    data = open(path, "rb").read()
    if len(data) < stride * height:
        sys.exit("%s: %d bytes, short of %d" %
                 (base, len(data), stride * height))
    hist = collections.Counter()
    magenta = 0
    for y in range(height):
        row = data[y * stride:y * stride + width * 4]
        for x in range(0, len(row), 4):
            b, g, r = row[x], row[x + 1], row[x + 2]
            if b > 150 and g < 90 and r > 150:
                magenta += 1
            # Bucket to 8 levels a channel so a gradient does not print 288000
            # distinct entries.
            hist[(r >> 5, g >> 5, b >> 5)] += 1
    mid = (height // 2) * stride + (width // 2) * 4
    centre = tuple(data[mid:mid + 3])
    print("%s: %dx%d stride %d, centre BGR %s, magenta %d/%d (%.1f%%)"
          % (base, width, height, stride, centre, magenta, width * height,
             100.0 * magenta / (width * height)))
    for (r, g, b), count in hist.most_common(6):
        print("  ~(%3d,%3d,%3d) %6.1f%%"
              % (r << 5, g << 5, b << 5, 100.0 * count / (width * height)))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: card-surface-stats.py FILE")
    main(sys.argv[1])
