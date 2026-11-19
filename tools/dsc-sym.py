#!/usr/bin/env python3
"""Name an address from a decompressed dyld symbols cache.

    dsc-sym.py SYMBOLS ADDR [ADDR ...]

SYMBOLS is the `dyld_shared_cache_arm64.symbols` companion, decompressed. On
this workstation it is stored as a decmpfs type-14 resource fork; `apfs-fuse`'s
LZBITMAP decoder expands it (`Decmpfs.cpp`, case 14). The expanded file is
itself a small dyld cache whose header at 0x4000 points at the nlist and string
tables for every image.

The match is the symbol with the largest value <= ADDR, the same convention a
debugger uses for a return address. A delta larger than the next symbol means
the address is not inside the named function; the caller decides whether that
matters.
"""
import mmap
import struct
import sys


def find_info(m):
    """Return (nlist_off, nlist_count, strings_off) of the local symbols info."""
    candidates = [0x4000]
    for base in candidates:
        if base + 16 > len(m):
            continue
        nlist_off, nlist_cnt, strings_off, strings_sz = struct.unpack_from(
            "<IIII", m, base)
        if (nlist_off and nlist_cnt and
                strings_off == nlist_off + nlist_cnt * 16 and
                strings_off + strings_sz <= len(m) - base):
            return base, nlist_off, nlist_cnt, strings_off
    # The symbols cache may put the info elsewhere; look for the same relation.
    for base in range(0x1000, min(0x100000, len(m)) - 16, 4):
        nlist_off, nlist_cnt, strings_off, strings_sz = struct.unpack_from(
            "<IIII", m, base)
        if (0x1000 <= nlist_off and 0 < nlist_cnt < 50000000 and
                strings_off == nlist_off + nlist_cnt * 16 and
                strings_off + strings_sz <= len(m) - base):
            return base, nlist_off, nlist_cnt, strings_off
    raise SystemExit("no local-symbols info found")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    targets = [int(a, 0) for a in sys.argv[2:]]
    f = open(path, "rb")
    m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    base, nlist_off, nlist_cnt, strings_off = find_info(m)
    nl_base = base + nlist_off
    str_base = base + strings_off
    best = {t: None for t in targets}
    for i in range(nlist_cnt):
        n_strx, _type, _sect, _desc, n_value = struct.unpack_from(
            "<IBBHQ", m, nl_base + i * 16)
        for t in targets:
            if n_value <= t and (best[t] is None or n_value > best[t][0]):
                best[t] = (n_value, n_strx)
    for t in targets:
        hit = best[t]
        if hit is None:
            print(f"{t:#x} -> (below the first symbol)")
            continue
        end = m.find(b"\0", str_base + hit[1], str_base + hit[1] + 300)
        name = m[str_base + hit[1]:end].decode("ascii", "replace") if end > 0 else "?"
        print(f"{t:#x} -> {name} +{t - hit[0]:#x}")


if __name__ == "__main__":
    main()
