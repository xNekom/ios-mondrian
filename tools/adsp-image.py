#!/usr/bin/env python3
"""Join a split Qualcomm peripheral image into the single file PAS takes.

The modem partition carries `adsp.mdt` plus `adsp.b00`, `adsp.b01`, ...: the
.mdt holds the ELF header, the program headers and the hash, and each .bNN
holds the bytes of program header NN at the offset that header names (NN=00
is the headers themselves). The secure-world PAS loader wants one file whose
program headers point inside it, so this writes that file: every piece at its
header's `p_offset`, gaps zeroed.

    tools/adsp-image.py OUT DIR

DIR holds NAME.mdt and NAME.bNN; the name is read from the .mdt argument's
basename. Nothing here touches a device: it reads ROM images only.

The joined file is what `qcom_mdt_parse` in the donor expects, and what
`docs/REFERENCE_PORTS.md` describes as installed on the host before boot.
"""

import os
import struct
import sys

PT_LOAD = 1
TYPE_MASK = 7 << 24
TYPE_HASH = 2 << 24


def parse_mdt(path):
    data = open(path, "rb").read()
    if len(data) < 52 or data[:4] != b"\x7fELF":
        raise SystemExit("%s: not an ELF" % path)
    if data[4] != 1 or data[5] != 1:
        raise SystemExit("%s: not a 32-bit little-endian ELF" % path)
    (e_phoff,) = struct.unpack_from("<I", data, 28)
    (e_phentsize, e_phnum) = struct.unpack_from("<HH", data, 42)
    if e_phentsize != 32 or not e_phnum:
        raise SystemExit("%s: unexpected program header table" % path)
    segments = []
    for i in range(e_phnum):
        at = e_phoff + i * 32
        p_type, p_offset, _vaddr, p_paddr, p_filesz, p_memsz, p_flags, _align = \
            struct.unpack_from("<8I", data, at)
        segments.append({
            "type": p_type,
            "offset": p_offset,
            "addr": p_paddr,
            "filesz": p_filesz,
            "memsz": p_memsz,
            "flags": p_flags,
            "hash": (p_flags & TYPE_MASK) == TYPE_HASH,
        })
    return data, segments


def main(argv):
    if len(argv) != 3:
        raise SystemExit(__doc__.splitlines()[0] + "\nusage: %s OUT DIR" % argv[0])
    out_path, directory = argv[1], argv[2]
    mdt = os.path.join(directory, "adsp.mdt")
    mdt_data, segs = parse_mdt(mdt)
    if not any(s["hash"] for s in segs):
        raise SystemExit("%s: no hash segment" % mdt)

    out_size = max(s["offset"] + s["filesz"] for s in segs if s["filesz"])
    out = open(out_path, "wb")
    out.truncate(out_size)
    lo = min(s["addr"] for s in segs if s["type"] == PT_LOAD and s["memsz"])
    hi = max(s["addr"] + s["memsz"] for s in segs if s["type"] == PT_LOAD and s["memsz"])

    for i, s in enumerate(segs):
        if not s["filesz"]:
            continue
        piece = os.path.join(directory, "adsp.b%02d" % i)
        if os.path.exists(piece):
            data = open(piece, "rb").read()
        elif i == 0:
            data = mdt_data[:s["filesz"]]
        else:
            raise SystemExit("%s: missing for program header %u" % (piece, i))
        if len(data) != s["filesz"]:
            raise SystemExit("%s: %u bytes, header says %u"
                             % (piece, len(data), s["filesz"]))
        out.seek(s["offset"])
        out.write(data)
    out.close()

    span = ((hi + 0xfff) & ~0xfff) - lo
    print("%s: %u program headers, %u bytes" % (out_path, len(segs), out_size))
    print("  load span 0x%x..0x%x (0x%x), carveout base 0x9fd00000"
          % (lo, hi, span))
    for s in segs:
        if s["hash"]:
            print("  hash segment at 0x%x, %u bytes"
                  % (s["offset"], s["filesz"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
