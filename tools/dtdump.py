#!/usr/bin/env python3
"""Read and write a device tree: dump it, or build a .dtb from a directory.

Used to read the *live* device tree of a phone (pulled from /proc/device-tree
in a recovery) instead of trusting a device tree source that may not be the
one the bootloader passes, and to put that tree back into a boot image so the
bootloader patches /chosen/linux,initrd-* in it.

    tools/dtdump.py mondrian.dtb                 # the whole tree
    tools/dtdump.py mondrian.dtb --find ufs      # only the matching nodes
    tools/dtdump.py mondrian.dtb --prop reg      # only this property
    tools/dtdump.py --build /tmp/mondrian-dt out.dtb   # directory -> .dtb
"""

import argparse
import os
import struct
import sys

FDT_BEGIN_NODE = 0x1
FDT_END_NODE = 0x2
FDT_PROP = 0x3
FDT_NOP = 0x4
FDT_END = 0x9
FDT_MAGIC = 0xD00DFEED


def _align4(n):
    return (n + 3) & ~3


def parse(blob):
    """Return the tree as a list of (path, {prop: value}) entries."""
    if len(blob) < 40 or struct.unpack_from('>I', blob, 0)[0] != 0xD00DFEED:
        raise ValueError('not a flattened device tree')
    totalsize, off_struct, off_strings = struct.unpack_from('>III', blob, 4)
    off_rsvmap, version, last_comp, boot_cpuid, size_strings, size_struct = \
        struct.unpack_from('>IIIIII', blob, 16)

    strings = blob[off_strings:off_strings + size_strings]

    def string_at(off):
        end = strings.index(b'\0', off)
        return strings[off:end].decode('utf-8', 'replace')

    out = []
    path = []
    pos = off_struct
    end_struct = off_struct + size_struct
    while pos < end_struct:
        (token,) = struct.unpack_from('>I', blob, pos)
        pos += 4
        if token == FDT_BEGIN_NODE:
            end = blob.index(b'\0', pos)
            name = blob[pos:end].decode('utf-8', 'replace')
            pos = _align4(end + 1)
            path.append(name)
            out.append(['/'.join([p for p in path if p]), {}])
        elif token == FDT_END_NODE:
            if path:
                path.pop()
        elif token == FDT_PROP:
            length, nameoff = struct.unpack_from('>II', blob, pos)
            pos += 8
            data = blob[pos:pos + length]
            pos = _align4(pos + length)
            name = string_at(nameoff)
            if out:
                out[-1][1][name] = data
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            break
        else:
            raise ValueError(f'bad token {token:#x} at {pos - 4:#x}')
    return out


def show_value(data):
    """Render a property value: string, cells, or hex bytes."""
    if len(data) == 0:
        return '(empty)'
    if data[-1] == 0 and b'\0' not in data[:-1]:
        return data[:-1].decode('utf-8', 'replace')
    if len(data) % 4 == 0:
        cells = struct.unpack('>' + 'I' * (len(data) // 4), data)
        if len(cells) == 1:
            return f'0x{cells[0]:x} ({cells[0]})'
        return ' '.join(f'0x{c:08x}' for c in cells)
    return data.hex()


def show_reg(data):
    """Decode a reg property as (base, size) pairs (2 address/size cells)."""
    if len(data) % 16:
        return show_value(data)
    pairs = []
    for i in range(0, len(data), 16):
        base, size = struct.unpack_from('>QQ', data, i)
        pairs.append(f'{base:#x}+{size:#x} ({size} bytes)')
    return ', '.join(pairs)


def dump_dir(root, find=None, prop=None, depth=99):
    """Walk a /proc/device-tree style directory and print the same text."""
    import os
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel = os.path.relpath(dirpath, root)
        node = '/' if rel == '.' else '/' + rel.replace(os.sep, '/')
        if node.count('/') > depth:
            continue
        if find and find not in node:
            continue
        print(node)
        for name in sorted(filenames):
            if prop and name != prop:
                continue
            path = os.path.join(dirpath, name)
            try:
                data = open(path, 'rb').read()
            except OSError as exc:
                print(f'    {name} = <{exc}>')
                continue
            if name in ('reg', 'ranges') and len(data) % 16 == 0 and len(data) >= 16:
                value = show_reg(data)
            else:
                value = show_value(data)
            print(f'    {name} = {value}')


def build(root):
    """Build a .dtb blob out of a /proc/device-tree style directory."""
    strings = bytearray()
    offsets = {}

    def stroff(name):
        if name not in offsets:
            offsets[name] = len(strings)
            strings.extend(name.encode('utf-8') + b'\0')
        return offsets[name]

    def align4(blob):
        return blob + b'\0' * ((4 - len(blob) % 4) % 4)

    struct_block = bytearray()

    def emit(dirpath, name):
        """Emit one node and, recursively, its children."""
        struct_block.extend(struct.pack('>I', FDT_BEGIN_NODE))
        struct_block.extend(align4(name.encode('utf-8') + b'\0'))
        for prop in sorted(n for n in os.listdir(dirpath)
                           if os.path.isfile(os.path.join(dirpath, n))):
            with open(os.path.join(dirpath, prop), 'rb') as f:
                data = f.read()
            struct_block.extend(struct.pack('>III', FDT_PROP, len(data), stroff(prop)))
            struct_block.extend(align4(data))
        for child in sorted(n for n in os.listdir(dirpath)
                            if os.path.isdir(os.path.join(dirpath, n))):
            emit(os.path.join(dirpath, child), child)
        struct_block.extend(struct.pack('>I', FDT_END_NODE))

    emit(root, '')

    rsvmap = struct.pack('>QQ', 0, 0)
    header_len = 40
    off_rsvmap = header_len
    off_struct = off_rsvmap + len(rsvmap)
    off_strings = off_struct + len(struct_block)
    total = off_strings + len(strings)

    header = struct.pack('>IIIIIIIIII', FDT_MAGIC, total, off_struct, off_strings,
                          off_rsvmap, 17, 16, 0, len(strings), len(struct_block))
    return header + rsvmap + bytes(struct_block) + bytes(strings)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dtb', nargs='?', help='the .dtb file or a /proc/device-tree directory')
    ap.add_argument('--build', metavar='DIR', help='build a .dtb from a directory')
    ap.add_argument('--out', help='output file for --build')
    ap.add_argument('--find', help='only nodes whose path contains this text')
    ap.add_argument('--prop', help='only this property')
    ap.add_argument('--depth', type=int, default=99, help='max depth to print')
    args = ap.parse_args()

    if args.build:
        blob = build(args.build)
        if args.out:
            with open(args.out, 'wb') as f:
                f.write(blob)
            print(f'{args.out}: {len(blob)} bytes')
        else:
            sys.stdout.buffer.write(blob)
        return 0

    if not args.dtb:
        ap.error('a .dtb file, a directory or --build is required')

    if os.path.isdir(args.dtb):
        try:
            dump_dir(args.dtb, args.find, args.prop, args.depth)
        except BrokenPipeError:
            pass
        return 0

    blob = open(args.dtb, 'rb').read()
    tree = parse(blob)
    for node, props in tree:
        depth = node.count('/')
        if depth > args.depth:
            continue
        if args.find and args.find not in node:
            continue
        print(f'{node}' if node else '/')
        for name, data in props.items():
            if args.prop and name != args.prop:
                continue
            if name in ('reg', 'ranges') and len(data) % 16 == 0 and len(data) >= 16:
                value = show_reg(data)
            else:
                value = show_value(data)
            print(f'    {name} = {value}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
