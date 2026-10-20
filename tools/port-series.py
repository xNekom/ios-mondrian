#!/usr/bin/env python3
"""Port a patch from the sweet series to the mondrian series.

  tools/port-series.py 0004-sweet-machine-config.patch
  tools/port-series.py --all

The mechanical part of the port is the board identifiers: the sweet series
guards its code with SWEET and calls its files, drivers and boot arguments
sweet_*.  On mondrian they become MONDRIAN and mondrian_*.  This script does
that renaming and leaves the parts that depend on the hardware alone, but
marks them so they are not missed.

It does not check that the result applies: the patch has to be tried with
git apply against the patched xnu tree, or with a CI run.
"""
import argparse
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWEET_SERIES = os.path.join(REPO_ROOT, 'xnu/patches')
MONDRIAN_SERIES = os.path.join(REPO_ROOT, 'xnu/patches-mondrian')

# Order matters: the longer names first.
RENAMES = [
    (r'ARM64_BOARD_CONFIG_SWEET', 'ARM64_BOARD_CONFIG_MONDRIAN'),
    (r'\bSWEET_VTIMER_INTID\b', 'MONDRIAN_VTIMER_INTID'),
    (r'\bSWEET_IPI_SGI\b', 'MONDRIAN_IPI_SGI'),
    (r'_PEXPERT_ARM64_SWEET_H', '_PEXPERT_ARM64_MONDRIAN_H'),
    (r'pexpert/arm64/SWEET\.h', 'pexpert/arm64/MONDRIAN.h'),
    (r'\bdefined\s*\(SWEET\)', 'defined(MONDRIAN)'),
    (r'\bdefined\s*\(SWEET\)\b', 'defined(MONDRIAN)'),
    (r'\bSweetPlatformExpert\b', 'MondrianPlatformExpert'),
    (r'sweet_ufs', 'mondrian_ufs'),
    (r'sweet-ufs', 'mondrian-ufs'),
    (r'sweet-fbcon', 'mondrian-fbcon'),
    (r'sweetfb_', 'mondrianfb_'),
    (r'sweettouch', 'mondriantouch'),
    (r'sweetkeys', 'mondriankeys'),
    (r'xiaomi,sweet', 'xiaomi,mondrian'),
    (r'\bSWEET\b', 'MONDRIAN'),
    (r'\bsweet\b', 'mondrian'),
    (r'\bSweet\b', 'Mondrian'),
]

# Hints that the hunk talks to the hardware and has to be looked at by hand.
HARDWARE_HINTS = {
    'ufs': 'the UFS host is a UFS 3.1 controller on SM8475, not the UFSHCI 2.1 '
            'sweet drives: the UTRD is 16 dwords and the PRDT is 64 bit',
    'goodix': 'the touch is a Goodix on QUPv3 SPI (0x990000), not on I2C',
    'geni': 'the QUPv3 wrapper is at 0x9c0000 with the SE4 at 0x990000',
    'spmi': 'the PMIC is a PM8008 (PMR735A + PM8350B), not a PM6150',
    'rpmh': 'the regulator votes are for the PM8008 rails, not the PM6150 LDO11',
    'dsi': 'the panel is an AMOLED on DSI D-PHY, not an LCD in DSC video mode',
    'framebuffer': 'the ABL framebuffer of a DSI panel is not the cont_splash_region',
    '0x9c000000': 'the framebuffer address of mondrian has to be measured',
    '0x17a00000': 'the GIC of SM8475 is at 0x17100000 (GICD) and 0x17180000 (GICR)',
    '0x1d84000': 'the UFS host is still at 0x1d84000, but it is a different IP',
    '16k': 'mondrian runs with 4 KiB pages: __ARM_16K_PG__ must not be defined',
    '0x4000': '4 KiB pages change the page table geometry (L2 block = 2 MB)',
}


def port_text(text):
    """Apply the board renames, return (new text, list of hardware notes)."""
    notes = []
    for pat, rep in RENAMES:
        text = re.sub(pat, rep, text)
    low = text.lower()
    for needle, note in HARDWARE_HINTS.items():
        if needle in low and note not in notes:
            notes.append(note)
    return text, notes


def port_file(path):
    with open(path, 'r', errors='surrogateescape') as f:
        text = f.read()
    new, notes = port_text(text)
    return new, notes


def out_name(name):
    return re.sub(r'\bsweet\b', 'mondrian', name.replace('-sweet-', '-mondrian-'))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('patch', nargs='*', help='patch file name (in xnu/patches/)')
    ap.add_argument('--all', action='store_true', help='port every patch of the series')
    ap.add_argument('--out', default=MONDRIAN_SERIES, help='output directory')
    ap.add_argument('--dry-run', action='store_true', help='only report')
    a = ap.parse_args()

    if a.all:
        names = sorted(n for n in os.listdir(SWEET_SERIES) if n.endswith('.patch'))
    else:
        names = a.patch
    if not names:
        ap.error('nothing to do: give a patch name or --all')

    os.makedirs(a.out, exist_ok=True)
    for name in names:
        src = os.path.join(SWEET_SERIES, name)
        if not os.path.exists(src):
            print(f'-- {name}: not in the sweet series', file=sys.stderr)
            continue
        text, notes = port_file(src)
        dst = os.path.join(a.out, out_name(name))
        if not a.dry_run:
            with open(dst, 'w', errors='surrogateescape') as f:
                f.write(text)
        print(f'-- {name} -> {os.path.relpath(dst, REPO_ROOT)}')
        for n in notes:
            print(f'   hardware: {n}')


if __name__ == '__main__':
    main()
