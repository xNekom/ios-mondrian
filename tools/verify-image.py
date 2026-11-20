#!/usr/bin/env python3
"""Verify that shim/out/shim-boot.img is the image this build produced.

Why this exists: `tools/wsl/image.sh` packs the payload, compresses it, appends
it to the shim and wraps the result in an Android boot image.  Each of those
steps can leave the previous file on disk (a SIGPIPE, a failed lz4, a stale
payload), and the phone then boots an older kernel while the new command
"does not exist".  `cycle.sh` catches that after a 2.5-minute boot by comparing
the ring's Darwin banner; this catches it in milliseconds, before `fastboot`.

The manifest (`shim/out/image-manifest.json`) records the sha256 of the kernel,
the raw payload, the LZ4P blob and the boot image, plus the command line the
payload really carries -- read from the payload header, not from the shell
variable that was supposed to reach it.

  tools/verify-image.py --record                 # after image.sh built them
  tools/verify-image.py                          # before boot, again
  tools/verify-image.py --expect-args "thermalthr=30"

Exit 0 verified, 1 refused.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULTS = {
    'image': REPO / 'shim/out/shim-boot.img',
    'payload': REPO / 'shim/out/payload.bin',
    'blob': REPO / 'shim/out/payload.lz4p',
    'kernel': REPO / 'xnu/out/kernel.development.mondrian',
    'manifest': REPO / 'shim/out/image-manifest.json',
}

ANDROID_MAGIC = b'ANDROID!'
LZ4P_MAGIC = b'LZ4P'
PAYLOAD_MAGICS = (b'MONDRIAN', b'SWEETXNU')
LZ4P_HEADER = 24
CMDLINE_OFF = 0x48
BOOT_LINE_LENGTH = 1024
# 1024 is the kernel's field; iOS userland reads kern.bootargs with a 608-byte
# buffer, so 608+ bytes is ENOMEM for watchdogd and launchd respawns it.  The
# number lives in tools/mkpayload.py; the test asserts the two agree.
USERLAND_BOOTARGS = 607
MIN_PAGE = 512
MAX_PAGE = 65536


class Refused(Exception):
    """The image, the payload or the manifest cannot be trusted."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def parse_boot_image(data: bytes) -> dict:
    """Locate the kernel section of an Android boot image (v0 through v4)."""
    if len(data) < 48 or data[:8] != ANDROID_MAGIC:
        raise Refused('not an Android boot image (no ANDROID! magic)')
    kernel_size = struct.unpack_from('<I', data, 8)[0]
    page = struct.unpack_from('<I', data, 36)[0]
    if page < MIN_PAGE or page > MAX_PAGE or page & (page - 1):
        raise Refused(f'implausible page size {page}')
    if kernel_size == 0:
        raise Refused('kernel section is empty')
    if page + kernel_size > len(data):
        raise Refused(f'kernel section needs {page + kernel_size} bytes, '
                      f'image has {len(data)}')
    return {'page': page, 'off': page, 'size': kernel_size, 'total': len(data)}


def parse_blob(data: bytes, kernel_off: int, kernel_size: int) -> dict:
    """Find the LZ4P blob the shim unpacks, inside the kernel section only."""
    section = data[kernel_off:kernel_off + kernel_size]
    at = section.rfind(LZ4P_MAGIC)
    if at < 0:
        raise Refused('no LZ4P blob in the kernel section: the payload was '
                      'not appended')
    if at + LZ4P_HEADER > len(section):
        raise Refused('LZ4P header is truncated')
    version, raw, comp = struct.unpack_from('<IQQ', section, at + 4)
    end = at + LZ4P_HEADER + comp
    if end > len(section):
        raise Refused(f'LZ4P blob runs {end - len(section)} bytes past the '
                      'kernel section: the image is truncated')
    if end != len(section):
        raise Refused(f'{len(section) - end} bytes follow the LZ4P blob; '
                      'the shim would not find them')
    return {'at': kernel_off + at, 'version': version, 'raw': raw,
            'comp': comp}


def parse_payload(data: bytes) -> dict:
    """Read the magic, count and command line out of the raw payload."""
    if len(data) < CMDLINE_OFF + BOOT_LINE_LENGTH:
        raise Refused(f'payload is {len(data)} bytes, shorter than its header')
    magic = data[:8]
    if magic not in PAYLOAD_MAGICS:
        raise Refused(f'payload magic {magic!r} is not MONDRIAN or SWEETXNU; '
                      'the shim would reject it')
    version, nsegs = struct.unpack_from('<II', data, 8)
    if version != 1:
        raise Refused(f'payload version {version}, this tool knows version 1')
    if nsegs == 0 or nsegs > 64:
        raise Refused(f'payload claims {nsegs} segments')
    raw = data[CMDLINE_OFF:CMDLINE_OFF + BOOT_LINE_LENGTH]
    cmdline = raw.split(b'\0', 1)[0].decode('utf-8', 'replace')
    return {'magic': magic, 'version': version, 'nsegs': nsegs,
            'cmdline': cmdline}


def entry(path: Path) -> dict:
    rel = path.relative_to(REPO) if path.is_relative_to(REPO) else path
    return {'path': rel.as_posix(), 'size': path.stat().st_size,
            'sha256': sha256_file(path)}


def record(paths: dict) -> dict:
    """Write the manifest from the files image.sh just produced."""
    for name in ('image', 'payload', 'blob', 'kernel'):
        if not paths[name].is_file():
            raise Refused(f'{paths[name]} is missing; the build did not finish')
    payload = parse_payload(paths['payload'].read_bytes())
    if len(payload['cmdline'].encode()) > USERLAND_BOOTARGS:
        raise Refused(f"the payload's command line is "
                      f"{len(payload['cmdline'].encode())} bytes, over the "
                      f'{USERLAND_BOOTARGS}-byte reader limit')
    manifest = {
        'built_at': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'cmdline': payload['cmdline'],
        'cmdline_bytes': len(payload['cmdline'].encode()),
        'magic': payload['magic'].decode(),
        'segments': payload['nsegs'],
        'image': entry(paths['image']),
        'payload': entry(paths['payload']),
        'blob': entry(paths['blob']),
        'kernel': entry(paths['kernel']),
    }
    tmp = paths['manifest'].parent / (paths['manifest'].name + '.tmp')
    tmp.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    tmp.replace(paths['manifest'])
    return manifest


def verify(paths: dict, expect_args: list[str]) -> tuple[list[str], dict]:
    """Compare every file with the manifest and the payload with itself."""
    if not paths['manifest'].is_file():
        raise Refused(f"{paths['manifest']} is missing; run image.sh "
                      '(or --record) first')
    try:
        manifest = json.loads(paths['manifest'].read_text(encoding='utf-8'))
    except ValueError as exc:
        raise Refused(f'manifest is not valid JSON: {exc}') from exc

    problems: list[str] = []
    for name in ('image', 'payload', 'blob', 'kernel'):
        path = paths[name]
        if not path.is_file():
            raise Refused(f'{path} is missing')
        got = sha256_file(path)
        want = str(manifest.get(name, {}).get('sha256', ''))
        if got.lower() != want.lower():
            problems.append(
                f'{path.name} sha256 {got[:16]} != manifest {want[:16]}; '
                'the file on disk is not the one this build recorded')
    if problems:
        return problems, manifest

    image = paths['image'].read_bytes()
    layout = parse_boot_image(image)
    blob = parse_blob(image, layout['off'], layout['size'])
    payload_bytes = paths['payload'].read_bytes()
    payload = parse_payload(payload_bytes)

    if blob['raw'] != len(payload_bytes):
        problems.append(f"LZ4P promises {blob['raw']} raw bytes, payload.bin is "
                        f'{len(payload_bytes)}')
    blob_bytes = paths['blob'].read_bytes()
    if len(blob_bytes) != LZ4P_HEADER + blob['comp']:
        problems.append(f'payload.lz4p is {len(blob_bytes)} bytes, the image '
                        f"carries {LZ4P_HEADER + blob['comp']}")
    image_blob = image[blob['at']:blob['at'] + LZ4P_HEADER + blob['comp']]
    if image_blob != blob_bytes:
        problems.append('the blob inside the image is not payload.lz4p: the '
                        'image was built before the current payload')

    if payload['cmdline'] != manifest.get('cmdline'):
        problems.append('the payload command line differs from the manifest')
    size = len(payload['cmdline'].encode())
    if size > USERLAND_BOOTARGS:
        problems.append(f'command line is {size} bytes, over the '
                        f'{USERLAND_BOOTARGS}-byte reader limit')
    tokens = set(payload['cmdline'].split())
    for words in expect_args:
        for word in words.split():
            if word not in tokens:
                problems.append(f'expected argument {word!r} is not in the '
                                'payload command line')
    return problems, manifest


def show(paths: dict, manifest: dict) -> None:
    image = paths['image']
    rel = image.relative_to(REPO) if image.is_relative_to(REPO) else image
    print(f'verify-image: OK')
    print(f"  image    {rel}  {image.stat().st_size / 1048576:.1f} MiB  "
          f"sha256 {manifest['image']['sha256'][:16]}")
    print(f"  payload  {manifest['payload']['path']}  "
          f"{manifest['payload']['size'] / 1048576:.1f} MiB  "
          f"sha256 {manifest['payload']['sha256'][:16]}")
    print(f"  cmdline  {manifest['cmdline_bytes']} bytes: "
          f"{manifest['cmdline']}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for name, path in DEFAULTS.items():
        ap.add_argument(f'--{name}', type=Path, default=path)
    ap.add_argument('--record', action='store_true',
                    help='write the manifest from the current build')
    ap.add_argument('--expect-args', action='append', default=[],
                    metavar='WORDS', help='each word must be in the cmdline')
    args = ap.parse_args()
    paths = {name: getattr(args, name) for name in DEFAULTS}

    try:
        if args.record:
            record(paths)
            print(f"verify-image: recorded {paths['manifest']}")
        problems, manifest = verify(paths, args.expect_args)
    except Refused as exc:
        print('verify-image: REFUSED')
        print(f'  - {exc}')
        return 1
    if problems:
        print('verify-image: REFUSED')
        for problem in problems:
            print(f'  - {problem}')
        return 1
    show(paths, manifest)
    return 0


if __name__ == '__main__':
    sys.exit(main())
