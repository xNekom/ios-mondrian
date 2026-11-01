#!/usr/bin/env python3
"""Check the LZ4P blob appended to a shim boot image.

    python3 tools/check-shim-blob.py shim/out/shim-boot.img

The shim unpacks the payload from the bytes right after its own _end, and
"cannot unpack the payload" means either the header is not what the build wrote
or the compressed data is cut short (a truncated image decompresses to less
than the raw size the header promises).
"""
import struct
import sys
from pathlib import Path

MAGIC = b'LZ4P'


def main():
    path = Path(sys.argv[1] if len(sys.argv) > 1 else 'shim/out/shim-boot.img')
    data = path.read_bytes()
    print(f'{path}: {len(data)} bytes ({len(data) / 1048576:.2f} MiB)')
    at = data.find(MAGIC)
    if at < 0:
        sys.exit('no LZ4P blob in the image')
    while at >= 0:
        version, raw, comp = struct.unpack_from('<IQQ', data, at + 4)
        end = at + 24 + comp
        print(f'  blob at 0x{at:x}: version {version}, raw {raw} '
              f'({raw / 1048576:.2f} MiB), compressed {comp} ({comp / 1048576:.2f} MiB)')
        print(f'    data ends at 0x{end:x}, image ends at 0x{len(data):x}: '
              f'{"OK" if end <= len(data) else "TRUNCATED"}'
              f' ({len(data) - end} bytes spare)')
        nxt = data.find(MAGIC, at + 1)
        if nxt < 0:
            break
        print(f'  (another LZ4P at 0x{nxt:x}: stray bytes, not the appended blob)')
        at = nxt


if __name__ == '__main__':
    main()
