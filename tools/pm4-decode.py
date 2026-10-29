#!/usr/bin/env python3
"""Decode a freedreno command stream into packet names.

    tools/pm4-decode.py -x mesa/src/freedreno/registers/adreno/adreno_pm4.xml STREAM.txt

STREAM.txt holds hex words, whitespace or one per line, as dumped by the kernel
(the `MondrianGPU: stream` line or a `pm4` file). The opcode names come from
Mesa's adreno_pm4.xml, so this stays correct as the driver's packet set moves.
A type-7 header on a6xx/a7xx is `7 << 28 | parity << 23 | opcode << 16 |
count`; the opcode is the low seven bits of bits [22:16].
"""
import argparse
import re
import sys
import xml.etree.ElementTree as ET


def load_names(path):
    """Only the packet-opcode enum: the same numbers mean other things in the
    register-field enums, and they would shadow the names that matter."""
    names = {}
    root = ET.parse(path).getroot()

    def local(element):
        return element.tag.rsplit('}', 1)[-1]      # the XML is namespaced

    for enum in (e for e in root.iter() if local(e) == 'enum'):
        if 'packet' not in (enum.get('name') or ''):
            continue
        for value in (e for e in enum if local(e) == 'value'):
            name, number = value.get('name'), value.get('value')
            if name is None or number is None:
                continue
            try:
                names.setdefault(int(number, 0), name)
            except ValueError:
                continue
    return names


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('stream', help='file of hex words, or "-" for stdin')
    ap.add_argument('-x', '--xml', required=True, help="Mesa's adreno_pm4.xml")
    args = ap.parse_args()

    text = sys.stdin.read() if args.stream == '-' else open(args.stream).read()
    words = [int(word, 16) for word in re.findall(r'(?:0x)?([0-9a-fA-F]{8})', text)]
    names = load_names(args.xml)

    index = 0
    while index < len(words):
        header = words[index]
        packet_type = header >> 28
        if packet_type == 7:
            opcode = (header >> 16) & 0x7f
            count = header & 0x3fff
            name = names.get(opcode, f'opcode 0x{opcode:02x}')
            payload = words[index + 1:index + 1 + count]
            print(f'{index:5d}: {name:<28} count {count:3d}  ' +
                  ' '.join(f'{word:08x}' for word in payload[:6]) +
                  (' ...' if count > 6 else ''))
            index += 1 + count
        elif packet_type == 4:
            count = header & 0x7f
            reg = (header >> 8) & 0x3ffff
            print(f'{index:5d}: {"CP_REG_WRITE (type 4)":<28} count {count:3d}  '
                  f'reg 0x{reg:05x} ' +
                  ' '.join(f'{word:08x}' for word in
                           words[index + 1:index + 1 + count]))
            index += 1 + count
        elif packet_type == 0:
            print(f'{index:5d}: {"CP_REG_WRITE (type 0)":<28} ' +
                  ' '.join(f'{word:08x}' for word in words[index:index + 2]))
            index += 2
        else:
            print(f'{index:5d}: type {packet_type} header {header:08x} (stop: a '
                  f'stream should not contain this)')
            break


if __name__ == '__main__':
    main()
