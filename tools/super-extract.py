#!/usr/bin/env python3
"""List and carve logical partitions out of a raw Android `super` image.

Android's dynamic partitions live in a container described by LP metadata
(system/core/fs_mgr/liblp). The container starts with two copies of a geometry
block, then two or more metadata slots whose first bytes are `0PLA`; each slot
holds four table descriptors (partitions, extents, groups, block devices)
followed by the tables themselves, and a partition is a list of extents where a
LINEAR extent is a sector range of the container.

The geometry block is not trusted here: some vendor images carry a stale or
partial one, while the metadata that matters parses cleanly. The slot is found
by its magic and its descriptors are checked for the four known entry sizes
(52, 24, 48, 64), which no other structure in the first megabytes matches.

    tools/super-extract.py super.img                     # list the partitions
    tools/super-extract.py super.img vendor_a out.img    # carve one

No device data is involved: this reads a ROM image, so it is safe in the tree.
"""

import struct
import sys

METADATA_MAGIC = 0x414C5030
SECTOR = 512
SCAN_LIMIT = 16 << 20
ENTRY_SIZES = (52, 24, 48, 64)


def descriptors(header, header_size):
    """The four table descriptors, found by their entry sizes."""
    for off in range(8, header_size - 47, 4):
        d = [struct.unpack("<III", header[off + 12 * i:off + 12 * (i + 1)])
             for i in range(4)]
        if tuple(x[2] for x in d) != ENTRY_SIZES:
            continue
        parts, exts, groups, devs = d
        if not (1 <= parts[1] <= 64 and 1 <= exts[1] <= 4096 and devs[1] >= 1):
            continue
        if not (parts[0] <= exts[0] <= groups[0] <= devs[0]):
            continue
        return parts, exts, groups, devs
    return None


def read_metadata(img):
    f = open(img, "rb")
    blob = f.read(SCAN_LIMIT)
    at = blob.find(struct.pack("<I", METADATA_MAGIC))
    while at >= 0:
        header = blob[at:at + 512]
        if len(header) >= 96:
            header_size = struct.unpack("<I", header[8:12])[0]
            if 72 <= header_size <= 4096:
                d = descriptors(header, header_size)
                if d is not None:
                    parts, exts, groups, devs = d
                    major, minor = struct.unpack("<HH", header[4:8])
                    tables = header_size + devs[0] + devs[1] * devs[2]
                    print("metadata at 0x%x: v%u.%u, header %u, tables %u"
                          % (at, major, minor, header_size, tables))
                    body = blob[at:at + tables]
                    base = header_size
                    partitions = [body[base + parts[0] + i * parts[2]:
                                        base + parts[0] + (i + 1) * parts[2]]
                                  for i in range(parts[1])]
                    extents = [body[base + exts[0] + i * exts[2]:
                                    base + exts[0] + (i + 1) * exts[2]]
                               for i in range(exts[1])]
                    f.close()
                    return partitions, extents
        at = blob.find(struct.pack("<I", METADATA_MAGIC), at + 1)
    f.close()
    raise SystemExit("no LP metadata slot in the first %u MB; is this a raw "
                     "super image?" % (SCAN_LIMIT >> 20))


def parse_partition(p, extents):
    name = p[:36].rstrip(b"\0").decode(errors="replace")
    _attrs, first, num, group = struct.unpack("<IIII", p[36:52])
    out = []
    for i in range(first, first + num):
        sectors, target_type, target_data, target_source = struct.unpack(
            "<QIQI", extents[i])
        out.append((sectors, target_type, target_data, target_source))
    return name, group, out


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    img = sys.argv[1]
    partitions, extents = read_metadata(img)
    print("%u partitions, %u extents" % (len(partitions), len(extents)))

    carved = None
    for p in partitions:
        name, group, exts = parse_partition(p, extents)
        size = sum(n for n, _t, _d, _s in exts) * SECTOR
        print("  %-16s %8.1f MB  group %u" % (name, size / (1 << 20), group))
        if len(sys.argv) > 3 and name == sys.argv[2]:
            carved = (name, exts)

    if len(sys.argv) <= 3:
        print("\nusage: %s IMAGE PARTITION OUT" % sys.argv[0])
        return 0
    if carved is None:
        raise SystemExit("no partition named %r" % sys.argv[2])

    name, exts = carved
    src = open(img, "rb")
    dst = open(sys.argv[3], "wb")
    written = 0
    for sectors, target_type, target_data, target_source in exts:
        if target_type == 1:                      # LP_TARGET_TYPE_ZERO
            dst.write(b"\0" * (sectors * SECTOR))
            written += sectors * SECTOR
            continue
        if target_type != 0:                      # LP_TARGET_TYPE_LINEAR
            raise SystemExit("extent type %u is not linear" % target_type)
        if target_source != 0:
            raise SystemExit("extent lives on block device %u, not super"
                             % target_source)
        src.seek(target_data * SECTOR)
        left = sectors * SECTOR
        while left:
            chunk = src.read(min(left, 1 << 20))
            if not chunk:
                raise SystemExit("short read at sector %u" % target_data)
            dst.write(chunk)
            left -= len(chunk)
            written += len(chunk)
    src.close()
    dst.close()
    print("wrote %s: %.1f MB" % (sys.argv[3], written / (1 << 20)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
