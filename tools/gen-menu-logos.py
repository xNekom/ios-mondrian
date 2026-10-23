#!/usr/bin/env python3
"""Generate the boot-menu logo bitmaps (shim/menu_logos.h).

Both silhouettes come from public vector sources and are rasterized here
into one-bit arrays with a small parser -> flatten -> even-odd pipeline.
No binary assets: the bitmaps are generated C arrays.

    Apple    the corporate silhouette (Wikimedia Commons
             "Apple_logo_black.svg", 814x1000, kept in the generated
             header with its trademark note; the file is hosted there
             as ineligible-for-copyright, the mark is Apple's)
    Android  Google Material Design Icons "android" (Apache 2.0)
             The icon is already just the head: dome, antennae, eyes.
             github.com/google/material-design-icons, viewBox 0 0 24 24

The parser covers the SVG command set (m M l L h H v V c C s S q Q a A
z Z, relative and implicit repeats); cubics are flattened, arcs go
through the standard center parameterization, and the fill is even-odd
with supersampling, so nested subpaths (the two eyes) punch out exactly
like in a browser.

    python3 tools/gen-menu-logos.py   # -> shim/menu_logos.h
"""
import math
import os
import re

APPLE_D = (
    "M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9"
    "134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5"
    "123.1s-85.5-39.5-164-39.5c-76.5 0-103.7 40.8-165.9 40.8s-105.6-57"
    "-155.5-127C46.7 790.7 0 663 0 541.8c0-194.4 126.4-297.5 250.8-297.5"
    "66.1 0 121.2 43.4 162.7 43.4 39.5 0 101.1-46 176.3-46 28.5 0 130.9"
    "2.6 198.3 99.2zm-234-181.5c31.1-36.9 53.1-88.1 53.1-139.3 0-7.1-.6"
    "-14.3-1.9-20.1-50.6 1.9-110.8 33.7-147.1 75.8-28.5 32.4-55.1 83.6"
    "-55.1 135.5 0 7.8 1.3 15.6 1.9 18.1 3.2.6 8.4 1.3 13.6 1.3 45.4 0 "
    "102.5-30.4 135.5-71.3z"
)

ANDROID_D = (
    "M17.6,9.48l1.84-3.18c0.16-0.31,0.04-0.69-0.26-0.85"
    "c-0.29-0.15-0.65-0.06-0.83,0.22l-1.88,3.24"
    "c-2.86-1.21-6.08-1.21-8.94,0L5.65,5.67"
    "c-0.19-0.29-0.58-0.38-0.87-0.2C4.5,5.65,4.41,6.01,4.56,6.3"
    "L6.4,9.48C3.3,11.25,1.28,14.44,1,18h22"
    "C22.72,14.44,20.7,11.25,17.6,9.48z"
    "M7,15.25c-0.69,0-1.25-0.56-1.25-1.25"
    "c0-0.69,0.56-1.25,1.25-1.25S8.25,13.31,8.25,14"
    "C8.25,14.69,7.69,15.25,7,15.25z"
    "M17,15.25c-0.69,0-1.25-0.56-1.25-1.25"
    "c0-0.69,0.56-1.25,1.25-1.25s1.25,0.56,1.25,1.25"
    "C18.25,14.69,17.69,15.25,17,15.25z"
)

CMD = "MmLlHhVvCcSsQqTtAaZz"
NUM = r"-?\d*\.?\d+(?:[eE][-+]?\d+)?"
TOK = re.compile(r"[%s]|%s" % (CMD, NUM))


def bezier(p0, c1, c2, p, n):
    for k in range(1, n + 1):
        t = k / n
        u = 1 - t
        yield (u ** 3 * p0[0] + 3 * u * u * t * c1[0] +
               3 * u * t * t * c2[0] + t ** 3 * p[0],
               u ** 3 * p0[1] + 3 * u * u * t * c1[1] +
               3 * u * t * t * c2[1] + t ** 3 * p[1])


def arc_points(p0, rx, ry, phi_deg, fA, fS, p, n):
    """SVG arc by the W3C 'center' parameterization."""
    x1, y1 = p0
    x2, y2 = p
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [p0, p]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(phi_deg)
    cos, sin = math.cos(phi), math.sin(phi)
    dx2 = (x1 - x2) / 2
    dy2 = (y1 - y2) / 2
    x1p = cos * dx2 + sin * dy2
    y1p = -sin * dx2 + cos * dy2
    lam = x1p ** 2 / rx ** 2 + y1p ** 2 / ry ** 2
    if lam > 1:
        s = math.sqrt(lam)
        rx, ry = s * rx, s * ry
    num_ = rx ** 2 * ry ** 2 - rx ** 2 * y1p ** 2 - ry ** 2 * x1p ** 2
    den = rx ** 2 * y1p ** 2 + ry ** 2 * x1p ** 2
    co = math.sqrt(max(0.0, num_ / den)) if den else 0.0
    if fA == fS:
        co = -co
    cxp = co * rx * y1p / ry
    cyp = -co * ry * x1p / rx
    cx = cos * cxp - sin * cyp + (x1 + x2) / 2
    cy = sin * cxp + cos * cyp + (y1 + y2) / 2

    def ang(ux, uy, vx, vy):
        d = math.sqrt(ux * ux + uy * uy) * math.sqrt(vx * vx + vy * vy)
        if d == 0:
            return 0.0
        c = max(-1.0, min(1.0, (ux * vx + uy * vy) / d))
        a = math.acos(c)
        return -a if ux * vy - uy * vx < 0 else a

    ux, uy = (x1p - cxp) / rx, (y1p - cyp) / ry
    vx, vy = (-x1p - cxp) / rx, (-y1p - cyp) / ry
    dA = ang(ux, uy, vx, vy)
    if not fS and dA > 0:
        dA -= 2 * math.pi
    if fS and dA < 0:
        dA += 2 * math.pi
    pts = []
    for k in range(n + 1):
        t = dA * k / n
        pts.append((cx + rx * math.cos(phi) * math.cos(t) -
                    ry * math.sin(phi) * math.sin(t),
                    cy + rx * math.sin(phi) * math.cos(t) +
                    ry * math.cos(phi) * math.sin(t)))
    return pts


def subpaths(d):
    """Parse to one polygon (list of points) per subpath."""
    toks = [m.group(0) for m in TOK.finditer(d)]
    i, polys, sub = 0, [], []
    cur = (0.0, 0.0)
    start = (0.0, 0.0)
    prev_c = None
    cmd = None

    def num():
        nonlocal i
        v = float(toks[i])
        i += 1
        return v

    def relp():
        x, y = num(), num()
        return (cur[0] + x, cur[1] + y) if rel else (x, y)

    while i < len(toks):
        t = toks[i]
        if not re.match(r"[%s]" % CMD, t):
            # an implicit repeat: the same command with another group of
            # numbers (chains of s, c, l...); an m repeats as a line.
            t = ("l" if rel else "L") if cmd in ("m", "M") else cmd
            if not t:
                raise ValueError("numbers before any command")
        else:
            i += 1
        cmd = t
        rel = t.islower()
        low = t.lower()

        def need():
            nonlocal polys, sub
            if sub:
                polys.append(sub)
                sub = []

        if low == "z":
            sub.append(start)
            cur = start
            prev_c = None
        elif low == "m":
            need()
            p = relp()
            cur = p
            start = p
            sub.append(p)
            prev_c = None
        elif low == "l":
            cur = relp()
            sub.append(cur)
            prev_c = None
        elif low == "h":
            x = num()
            if rel:
                x += cur[0]
            cur = (x, cur[1])
            sub.append(cur)
            prev_c = None
        elif low == "v":
            y = num()
            if rel:
                y += cur[1]
            cur = (cur[0], y)
            sub.append(cur)
            prev_c = None
        elif low == "c":
            c1, c2, p = relp(), relp(), relp()
            sub += list(bezier(cur, c1, c2, p, 16))
            cur, prev_c = p, c2
        elif low == "s":
            c1 = (2 * cur[0] - prev_c[0], 2 * cur[1] - prev_c[1]) \
                if prev_c else cur
            c2, p = relp(), relp()
            sub += list(bezier(cur, c1, c2, p, 16))
            cur, prev_c = p, c2
        elif low == "q":
            qc, p = relp(), relp()
            c1 = (cur[0] + 2 / 3 * (qc[0] - cur[0]),
                  cur[1] + 2 / 3 * (qc[1] - cur[1]))
            c2 = (p[0] + 2 / 3 * (qc[0] - p[0]),
                  p[1] + 2 / 3 * (qc[1] - p[1]))
            sub += list(bezier(cur, c1, c2, p, 16))
            cur, prev_c = p, c2
        elif low == "a":
            rx, ry, phi = num(), num(), num()
            fA, fS = num() > 0.5, num() > 0.5
            p = relp()
            if sub:
                sub += arc_points(cur, rx, ry, phi, fA, fS, p, 32)[1:]
            cur = p
            prev_c = None
        else:
            raise ValueError("bad token " + t)
    need()
    return polys


class Grid:
    def __init__(self, w, h, sup=2):
        self.w, self.h, self.sup = w, h, sup
        self.px = [[0] * w for _ in range(h)]


def fill(g, polys):
    """Even-odd fill by scanline: at each sample row collect the x
    crossings, sort them, and fill between the pairs (sample rows = the
    supersampling over the pixel height)."""
    edges = []
    for poly in polys:
        for a, b in zip(poly, poly[1:] + poly[:1]):
            if a[1] != b[1]:
                yl, yh = min(a[1], b[1]), max(a[1], b[1])
                if yl < g.h and yh >= 0:
                    edges.append((min(a, b, key=lambda p: p[1]),
                                  max(a, b, key=lambda p: p[1]), yl, yh))
    sup = g.sup
    for y in range(g.h):
        hit = [0] * g.w
        for sy in range(sup):
            py = y + (sy + 0.5) / sup
            xs = []
            for a, b, yl, yh in edges:
                if yl <= py < yh:
                    xs.append(a[0] + (py - a[1]) * (b[0] - a[0]) /
                              (b[1] - a[1]))
            xs.sort()
            # even-odd: the sorted crossings open and close spans
            for k in range(0, len(xs) - 1, 2):
                x1, x2 = xs[k], xs[k + 1]
                x0 = max(0, int(math.floor(x1 - 0.5)))
                x3 = min(g.w - 1, int(math.ceil(x2 - 0.5)))
                for x in range(x0, x3 + 1):
                    if x1 <= x + 0.5 < x2:
                        hit[x] += 1
        for x in range(g.w):
            if hit[x] * 2 >= sup:
                g.px[y][x] = 1


def crop(g, margin=1):
    pts = [(y, x) for y in range(g.h) for x in range(g.w) if g.px[y][x]]
    if not pts:
        return g
    y0 = max(0, min(p[0] for p in pts) - margin)
    y1 = min(g.h, max(p[0] for p in pts) + margin + 1)
    x0 = max(0, min(p[1] for p in pts) - margin)
    x1 = min(g.w, max(p[1] for p in pts) + margin + 1)
    out = Grid(x1 - x0, y1 - y0)
    out.px = [row[x0:x1] for row in g.px[y0:y1]]
    return out


def rasterize(d, px_per_unit, padding=1, sup=2):
    polys = subpaths(d)
    xs = [p[0] for poly in polys for p in poly]
    ys = [p[1] for poly in polys for p in poly]
    x0, y0 = min(xs), min(ys)
    w = int(math.ceil(math.ceil((max(xs) - x0) * px_per_unit))) + 2 * padding
    h = int(math.ceil(math.ceil((max(ys) - y0) * px_per_unit))) + 2 * padding
    g = Grid(w, h, sup)
    for poly in polys:
        for k, p in enumerate(poly):
            poly[k] = ((p[0] - x0) * px_per_unit + padding,
                       (p[1] - y0) * px_per_unit + padding)
    fill(g, polys)
    return crop(g, margin=0)


def pack(name, g):
    rows = []
    for y in range(g.h):
        cells = g.px[y]
        pad = (8 - g.w % 8) % 8
        row = cells + [0] * pad
        b = []
        for i in range(0, g.w + pad, 8):
            byte = 0
            for bit in range(8):
                byte = (byte << 1) | row[i + bit]
            b.append("0x%02x" % byte)
        rows.append("\t" + ", ".join(b) + ",")
    return ("static const unsigned char %s[%d * %d] = {\n%s\n};\n"
            "#define %s_W %d\n#define %s_H %d\n"
            % (name, g.w, g.h, "\n".join(rows), name, g.w, name, g.h))


def main():
    apple = rasterize(APPLE_D, 0.40)     # the 814x1000 corporate path, native 1x blit
    andro = rasterize(ANDROID_D, 14)     # 24 * 14 = 336 px wide, native 1x blit
    out = (
        "/*\n"
        " * The logos of the boot menu, rasterized by\n"
        " * tools/gen-menu-logos.py from public vector sources:\n"
        " *   Apple:   Wikimedia Commons \"Apple_logo_black.svg\"\n"
        " *            (814x1000; the mark is a trademark of Apple Inc.)\n"
        " *   Android: Google Material Icons \"android\" (Apache 2.0)\n"
        " * One bit per pixel, MSB first per row. Do not edit the bit maps\n"
        " * by hand; change the generator and run it.\n"
        " */\n"
        "#pragma once\n"
        "#include <stdint.h>\n\n"
        "/* The Apple fruit, white. */\n"
        + pack("m_apple", apple) + "\n"
        "/* The Android robot head, green. */\n"
        + pack("m_android", andro) + "\n"
    )
    path = os.path.join(os.path.dirname(__file__), "..", "shim", "menu_logos.h")
    with open(path, "w") as f:
        f.write(out)
    print("apple %dx%d, android %dx%d -> %s" %
          (apple.w, apple.h, andro.w, andro.h, os.path.normpath(path)))


if __name__ == "__main__":
    main()
