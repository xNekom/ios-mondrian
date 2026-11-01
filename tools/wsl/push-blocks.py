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
import subprocess
import sys
import tempfile


def adb(*args, **kwargs):
    return subprocess.run(('adb',) + args, check=kwargs.pop('check', True), **kwargs)


def shell(command, capture=False, binary=False):
    if binary:
        return subprocess.run(('adb', 'exec-out', command), check=True,
                              stdout=subprocess.PIPE).stdout
    result = subprocess.run(('adb', 'shell', command), check=True,
                            stdout=subprocess.PIPE if capture else None,
                            text=not capture)
    return result.stdout.strip() if capture else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('old')
    ap.add_argument('new')
    ap.add_argument('--device', default='/dev/block/sda37')
    ap.add_argument('--block', type=int, default=4096)
    ap.add_argument('--runs', type=int, default=512,
                    help='blocks per write (512 x 4 KiB = 2 MiB)')
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

    # one temp file per run, pushed and written; /tmp on the phone is tmpfs
    with tempfile.TemporaryDirectory() as tmp, open(args.new, 'rb') as new:
        for index, (first, count) in enumerate(runs):
            new.seek(first * block)
            data = new.read(count * block)
            path = os.path.join(tmp, 'run.bin')
            with open(path, 'wb') as out:
                out.write(data)
            remote = f'/tmp/mondrian-run-{index}.bin'
            adb('push', path, remote, check=True, stdout=subprocess.DEVNULL)
            shell(f'dd if={remote} of={args.device} bs={block} seek={first} '
                  f'count={count} conv=notrunc 2>/dev/null')
            # read it back before trusting it
            back = shell(f'dd if={args.device} bs={block} skip={first} count={count} 2>/dev/null',
                         binary=True)
            if back != data:
                sys.exit(f'error: block {first} (+{count}) did not read back as written')
            shell(f'rm -f {remote}', capture=True)
            done = total - (len(runs) - index - 1) * 0  # progress text only
            print(f'  {index + 1}/{len(runs)} ok ({count} blocks at {first})', flush=True)
    shell('sync', capture=True)
    print('done')
    return 0


if __name__ == '__main__':
    sys.exit(main())
