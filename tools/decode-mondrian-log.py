#!/usr/bin/env python3
"""Decode the raw 4 MiB MONDRIAN persistent-console area.

The input is the header block plus the ring, read from the final 1025 UFS
blocks of userdata (4096 bytes per block). For example:

    tools/decode-mondrian-log.py mondrian-log.raw > mondrian-console.log
"""

import argparse
from pathlib import Path
import struct
import sys


BLOCK_SIZE = 4096
RING_SIZE = 4 << 20
HEADER = struct.Struct("<8sIIQQ")


def decode(path: Path) -> bytes:
    raw = path.read_bytes()
    if len(raw) != BLOCK_SIZE + RING_SIZE:
        raise ValueError(
            f"expected {BLOCK_SIZE + RING_SIZE} bytes, got {len(raw)}"
        )

    magic, version, ring_size, total, seq = HEADER.unpack_from(raw)
    if magic[:7] != b"MONDLOG":
        raise ValueError(f"bad magic: {magic!r}")
    if version != 1 or ring_size != RING_SIZE:
        raise ValueError(f"unsupported header: version={version}, size={ring_size}")

    ring = raw[BLOCK_SIZE:]
    have = min(total, ring_size)
    start = (total - have) % ring_size
    ordered = (ring[start:] + ring[:start])[:have]
    print(
        f"MONDLOG v{version}: {have} bytes, ring {ring_size}, flush seq {seq}",
        file=sys.stderr,
    )
    return ordered


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw", type=Path, help="header block followed by the 4 MiB ring")
    args = parser.parse_args()
    try:
        sys.stdout.buffer.write(decode(args.raw))
    except (OSError, ValueError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
