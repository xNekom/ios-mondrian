#!/usr/bin/env python3
"""Write an image back to the phone, only the blocks that changed.

    tools/wsl/push-blocks.py OLD.img NEW.img [--device /dev/block/sda37]
        [--block 4096] [--runs 512] [--dry-run]

OLD.img is the dump the new image was derived from, so a dylib swap pushes a
few MB instead of the whole 16 GiB partition. Every run is written with dd,
read back, and compared before the next one is sent: a bad block is reported,
not left on the phone.

The phone has to be in recovery with adb (its /tmp is tmpfs and large enough
for the runs). Writing userdata is in the allowed set; nothing else is touched.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile


def adb(*args, **kwargs):
    return subprocess.run((ADB,) + args, check=kwargs.pop('check', True), **kwargs)


def find_adb():
    """adb, or the Windows one from WSL (where USB is only visible to it)."""
    if os.environ.get('ADB'):
        return os.environ['ADB']
    for candidate in ('adb', '/mnt/c/platform-tools/adb.exe'):
        if os.path.isfile(candidate) or shutil.which(candidate):
            return candidate
    return 'adb'


ADB = find_adb()


def shell(command, binary=False):
    if binary:
        return subprocess.run((ADB, 'exec-out', command), check=True,
                              stdout=subprocess.PIPE).stdout
    return subprocess.run((ADB, 'shell', command), check=True,
                          stdout=subprocess.PIPE).stdout


def write_blocks(device, first, data, block, stage):
    """dd one run on the phone from a file adb can see.

    A pipe through `adb shell` is not usable here: the Windows adb translates
    CR/LF on stdin and the data arrives corrupted (measured: the volume header
    survived, the second run did not). The staging file has to live on a path
    the Windows adb can open, which is why the caller picks /mnt/c.
    """
    path = os.path.join(stage, 'run.bin')
    with open(path, 'wb') as out:
        out.write(data)
    remote = '/tmp/mondrian-run.bin'
    adb('push', path, remote, stdout=subprocess.DEVNULL)
    command = (f'dd if={remote} of={device} bs={block} seek={first} '
               f'count={len(data) // block} conv=notrunc 2>/dev/null')
    subprocess.run((ADB, 'shell', command), check=True)
    subprocess.run((ADB, 'shell', f'rm -f {remote}'), check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('old')
    ap.add_argument('new')
    ap.add_argument('--device', default='/dev/block/sda37')
    ap.add_argument('--block', type=int, default=4096)
    ap.add_argument('--runs', type=int, default=512,
                    help='blocks per write (512 x 4 KiB = 2 MiB)')
    ap.add_argument('--stage', default=os.environ.get('PUSH_STAGE', 'backup/.stage'),
                    help='directory for the transfer file (must be visible to adb; '
                         'backup/ is gitignored)')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    block = args.block
    with open(args.old, 'rb') as old, open(args.new, 'rb') as new:
        old_size = os.fstat(old.fileno()).st_size
        new_size = os.fstat(new.fileno()).st_size
        if new_size > old_size:
            sys.exit(f'error: {args.new} is larger than {args.old}')

        runs = []           # (first_block, blocks)
        changed = 0
        at = 0
        while True:
            a = old.read(block)
            b = new.read(block)
            if not a and not b:
                break
            if a != b:
                changed += 1
                if runs and runs[-1][0] + runs[-1][1] == at // block and runs[-1][1] < args.runs:
                    runs[-1] = (runs[-1][0], runs[-1][1] + 1)
                else:
                    runs.append((at // block, 1))
            at += block

    total = changed * block
    print(f'{changed} blocks changed ({total / 1048576:.1f} MiB) in {len(runs)} runs')

    if args.dry_run or not runs:
        return 0

    # one run at a time; every run is read back before the next is sent
    os.makedirs(args.stage, exist_ok=True)
    with open(args.new, 'rb') as new:
        for index, (first, count) in enumerate(runs):
            new.seek(first * block)
            data = new.read(count * block)
            write_blocks(args.device, first, data, block, args.stage)
            back = shell(f'dd if={args.device} bs={block} skip={first} count={count} 2>/dev/null',
                         binary=True)
            if back != data:
                sys.exit(f'error: block {first} (+{count}) did not read back as written')
            print(f'  {index + 1}/{len(runs)} ok ({count} blocks at {first})', flush=True)
    print('done')
    return 0


if __name__ == '__main__':
    sys.exit(main())
