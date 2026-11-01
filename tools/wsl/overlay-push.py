#!/usr/bin/env python3
"""Push the blocks a qcow2 overlay wrote onto the phone.

    tools/wsl/overlay-push.py work.qcow2 [--device /dev/block/sda37] [--dry-run]

The root image is dumped from the phone once and never copied: writing through a
qcow2 overlay on top of it (`qemu-img create -f qcow2 -b dump.img -F raw
work.qcow2`) records exactly the blocks a change touched, and this sends those
back. `qemu-img map` gives the extents the overlay itself allocated (depth 0),
so nothing has to be compared against the dump and nothing is written twice.

Every run is read back and compared before the next one is sent.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile


def find_adb():
    if os.environ.get('ADB'):
        return os.environ['ADB']
    for candidate in ('adb', '/mnt/c/platform-tools/adb.exe'):
        if os.path.isfile(candidate) or shutil.which(candidate):
            return candidate
    return 'adb'


ADB = find_adb()
BLOCK = 4096
RUN = 512 * BLOCK       # 2 MiB per write


def adb(*args, **kwargs):
    return subprocess.run((ADB,) + args, check=kwargs.pop('check', True), **kwargs)


def shell(command, binary=False):
    if binary:
        return subprocess.run((ADB, 'exec-out', command), check=True,
                              stdout=subprocess.PIPE).stdout
    return subprocess.run((ADB, 'shell', command), check=True,
                          stdout=subprocess.PIPE).stdout


def overlay_extents(path):
    """The ranges this overlay holds data for, merged into runs."""
    out = subprocess.run(('qemu-img', 'map', '--output=json', path),
                         check=True, stdout=subprocess.PIPE, text=True).stdout
    ranges = []
    for extent in json.loads(out):
        if extent['depth'] != 0 or not extent['data'] or extent['length'] == 0:
            continue
        start, end = extent['start'], extent['start'] + extent['length']
        if ranges and ranges[-1][1] == start:
            ranges[-1] = (ranges[-1][0], end)
        else:
            ranges.append((start, end))
    return ranges


def read_overlay(path, start, length):
    return subprocess.run(
        ('qemu-img', 'dd', '-f', 'qcow2', f'if={path}', 'of=-', '-O', 'raw',
         f'bs={BLOCK}', f'skip={start // BLOCK}', f'count={length // BLOCK}'),
        check=True, stdout=subprocess.PIPE).stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('overlay')
    ap.add_argument('--device', default='/dev/block/sda37')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    ranges = overlay_extents(args.overlay)
    total = sum(end - start for start, end in ranges)
    print(f'{len(ranges)} changed extents, {total / 1048576:.1f} MiB')
    if args.dry_run or not ranges:
        for start, end in ranges[:20]:
            print(f'  0x{start:x} .. 0x{end:x} ({(end - start) / 1024:.0f} KiB)')
        return 0

    written = 0
    index = 0
    with tempfile.TemporaryDirectory() as tmp:
        for start, end in ranges:
            at = start
            while at < end:
                length = min(RUN, end - at)
                data = read_overlay(args.overlay, at, length)
                if len(data) != length:
                    sys.exit(f'error: short read at 0x{at:x}')
                path = os.path.join(tmp, 'run.bin')
                with open(path, 'wb') as out:
                    out.write(data)
                remote = f'/tmp/mondrian-overlay-{index}.bin'
                adb('push', path, remote, stdout=subprocess.DEVNULL)
                shell(f'dd if={remote} of={args.device} bs={BLOCK} '
                      f'seek={at // BLOCK} count={length // BLOCK} conv=notrunc 2>/dev/null')
                back = shell(f'dd if={args.device} bs={BLOCK} skip={at // BLOCK} '
                             f'count={length // BLOCK} 2>/dev/null', binary=True)
                if back != data:
                    sys.exit(f'error: 0x{at:x} did not read back as written')
                shell(f'rm -f {remote}')
                written += length
                index += 1
                print(f'  {written / 1048576:.1f}/{total / 1048576:.1f} MiB '
                      f'(0x{at:x} +{length // 1024} KiB) ok', flush=True)
                at += length
    shell('sync')
    print('done')
    return 0


if __name__ == '__main__':
    sys.exit(main())
