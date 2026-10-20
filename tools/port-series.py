#!/usr/bin/env python3
"""Port the sweet patch series to the mondrian series.

  tools/port-series.py --all          # port everything that is not hardware
  tools/port-series.py 0016 0017      # port single patches
  tools/port-series.py --all --dry-run

The mechanical part of the port is the board identifiers: the sweet series
guards its code with SWEET and calls its files, drivers and boot arguments
sweet_*.  On mondrian they become MONDRIAN and mondrian_*.  This script does
that renaming.

The patches that talk to the hardware of the sweet phone are not ported: a
renamed copy would compile and then not work, because SM8475 has a UFS 3.1
host, an AMOLED panel on DSI D-PHY, a Goodix touch on SPI and a PM8008
instead of the PM6150.  They are listed in HARDWARE_PATCHES with what each
of them needs; docs/MONDIAN_PORT.md has the details.

The result is checked with tools/apply-series.py, which applies the series
to an xnu tree in seconds.
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
    (r'\bSweetPlatformExpert\b', 'MondrianPlatformExpert'),
    (r'sweet_ufs', 'mondrian_ufs'),
    (r'sweet-ufs', 'mondrian-ufs'),
    (r'sweet-fbcon', 'mondrian-fbcon'),
    (r'sweetfb_', 'mondrianfb_'),
    (r'\bsweet(hidtest|iolog|null|scan|fb|touch|keys|usb)\b', r'mondrian\1'),
    (r'sweettouch', 'mondriantouch'),
    (r'sweetkeys', 'mondriankeys'),
    (r'xiaomi,sweet', 'xiaomi,mondrian'),
    # the early console draws on the splash of the board: the address and the
    # geometry of the panel. On the SM8475 the cont_splash_region is at
    # 0xb8000000 and the panel is 1440x3200 (stride 5760). Writing to the
    # sweet address would hit the firmware area of the SM8475.
    (r'0x9c000000', '0xb8000000'),
    (r'\bEARLY_WIDTH 1080u\b', 'EARLY_WIDTH 1440u'),
    (r'\bEARLY_HEIGHT 2400u\b', 'EARLY_HEIGHT 3200u'),
    (r'\bEARLY_STRIDE \(4320u / 4\)', 'EARLY_STRIDE (5760u / 4)'),
    (r'\b4320\b', '5760'),
    # the last row the early console writes on: the sweet screen is 2400
    # pixels high, the mondrian one 3200
    (r'\b2368\b', '3168'),
    # the CPU compatible string: sweet is a Kryo 470 (Cortex-A76/A55),
    # mondrian a Kryo 700 (Cortex-X2/A710/A510)
    (r'qcom,kryo470', 'qcom,kryo'),
    # the description of the board, so that the context lines of the
    # ported patches still match the files they modify
    (r'Redmi Note 10 Pro, SM7150\): MASTER', 'POCO F5 Pro, SM8475): MASTER'),
    (r'Redmi Note 10 Pro bootstrap console', 'POCO F5 Pro bootstrap console'),
    (r'Redmi Note 10 Pro', 'POCO F5 Pro'),
    (r'Snapdragon 732G\): Kryo 470 = Cortex-A76 \+ Cortex-A55, ARMv8\.2, no PAC\.',
     'Snapdragon 8+ Gen 1): Cortex-X2 + Cortex-A710 + Cortex-A510, ARMv9.0, no PAC.'),
    (r'Kryo 470: Cortex-A76 \+ Cortex-A55', 'Cortex-X2 + Cortex-A710 + Cortex-A510'),
    (r'Kryo 470', 'Kryo 700'),
    (r'Cortex-A76/A55', 'Cortex-X2/A710/A510'),
    (r'\b16K pages\b', '4K pages'),
    # the board specific identifiers: SWEET_SMP_MAX_CPUS, SWEET_FB_*,
    # SWEET_LOG_*, sweet_ufs.c, sweet_keys.c, ...
    (r'\bSWEET_([A-Z0-9_]+)\b', r'MONDRIAN_\1'),
    (r'\bsweet_([a-z0-9_]+)\b', r'mondrian_\1'),
    # the file names: SweetCPU.cpp, SweetPlatformExpert.cpp, SWEET.h
    (r'\bSweet([A-Z]\w*)', r'Mondrian\1'),
    (r'\bSWEET\.h\b', 'MONDRIAN.h'),
    (r'\bSWEET\b', 'MONDRIAN'),
    (r'\bsweet\b', 'mondrian'),
    (r'\bSweet\b', 'Mondrian'),
]

# Patches that talk to the hardware of the sweet phone.
HARDWARE_PATCHES = {
    '0028': 'UFS root device: sweet drives a UFSHCI 2.1 host, mondrian a UFS 3.1 one',
    '0029': 'UFS: unsealed root volume, needs the UFS 3.1 driver',
    '0030': 'UFS writes, needs the UFS 3.1 driver',
    '0031': 'UFS: read/write root, needs the UFS 3.1 driver',
    '0034': 'UFS DMA above 4G, needs the UFS 3.1 driver',
    '0046': 'IOSurface and IOMobileFramebuffer: the panel is an AMOLED on DSI',
    '0047': 'the persistent console log writes to the end of the userdata partition: UFS',
    '0054': 'the process sampler reads the UFS root and the framebuffer',
    '0055': 'the AKS state sampler extends the process sampler',
    '0056': 'throttled panel copy: same',
    '0060': 'keys over SPMI and touch over I2C: mondrian has a PM8008 and SPI',
    '0061': 'the display size: the framebuffer of the panel is not there yet',
    '0062': 'RPMh vote for the touch rail and the battery: the rails differ',
    '0063': 'GENI I2C FIFO and the Goodix GT9896: mondrian is Goodix on SPI',
    '0067': 'the console mute is a display thing',
    '0068': 'the IOSurface lookup: needs the IOSurface patch',
    '0069': 'UFS: batched log flushes',
    '0071': 'the touch edge events need the display mapping of the panel',
    '0072': 'USB probe: the SM8475 DWC3 needs its own configuration',
    '0073': 'USB device',
    '0074': 'USB VBUS override',
    '0075': 'USB ECM',
    '0076': 'USB receive path',
    '0077': 'USB live log',
    '0079': 'display power: the panel is an AMOLED on DSI',
    '0081': 'USB link state',
}

# Ported by hand, not copied.
HAND_WRITTEN = {
    '0004': 'the machine config (xnu/patches-mondrian/0001)',
    '0006': 'the master config (xnu/patches-mondrian/0002)',
}

# Patches of which only some files are ported: the rest needs the hardware
# of the sweet phone, but these parts are generic.
PARTIAL = {
    '0046': ['iokit/Kernel/arm/SweetPlatformExpert.cpp'],
}


def fix_hunk_counts(text):
    """Recompute the counts of the hunk headers.

    Filtering a patch can cut a hunk short (the context lines after the
    change belong to the group), and a hunk with a wrong count is
    "corrupt" for git apply.
    """
    trailing = text.endswith('\n')
    lines = text.split('\n')
    if trailing:
        # the empty string after the last newline is not a context line
        lines = lines[:-1]
    out = []
    group = []          # the lines of the current file group

    for line in lines:
        if line.startswith('diff --git') or line.startswith('--- '):
            if group:
                out.extend(fix_group(group))
                group = []
        group.append(line)
    if group:
        out.extend(fix_group(group))
    result = '\n'.join(out)
    return result + '\n' if trailing else result


def fix_group(group):
    """The lines of one file group, with the hunk headers corrected."""
    out = []
    i = 0
    while i < len(group):
        line = group[i]
        m = re.match(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$', line)
        if not m:
            out.append(line)
            i += 1
            continue
        ao = an = 0
        j = i + 1
        while j < len(group):
            l = group[j]
            if l.startswith('@@') or l.startswith('diff --git') or l.startswith('--- '):
                break
            if l.startswith('+'):
                an += 1
            elif l.startswith('-'):
                ao += 1
            elif l.startswith(' '):
                ao += 1
                an += 1
            else:
                # an empty line is a context line whose space was stripped
                ao += 1
                an += 1
            j += 1
        out.append(f'@@ -{m.group(1)},{ao} +{m.group(3)},{an} @@{m.group(5)}')
        out.extend(group[i + 1:j])
        i = j
    return out


# Context lines that a ported patch carries but that do not exist in the
# mondrian tree: the file or the entry comes from a hardware patch that is
# not ported yet. The lines are dropped and the hunk counts are fixed.
DROP_LINES = {
    '0058': [
        # the display files are added by the display patch, which is not ported
        'iokit/Kernel/arm/SweetSurface.cpp',
        'iokit/Kernel/arm/SweetFramebuffer.cpp',
        # the context after the display entry of the kernel config table
        '#endif',
        "'IOClass'         = IOPanicPlatform;",
    ],
}

# Context blocks of a ported patch that have to point at something else: the
# entry they name is added by a hardware patch that is not ported yet.
CONTEXT_BLOCKS = {
    '0058': [
        # the HID entries go after the platform expert entry, not after the
        # display one (the display patch is not ported yet)
        (['    "     \'IOProviderClass\' = IOPlatformDevice;"',
          '    "     \'IONameMatch\'     = \'sweet,display\';"',
          '    "   },"'],
         ['    "     \'IONameMatch\'     = \'xiaomi,sweet\';"',
          '    "     \'IOProbeScore\'    = 10000:32;"',
          '    "   },"']),
    ],
    '0059': [
        # the platform expert ends with the /arm-io nubs (the generic part of
        # the display patch), so the context is one line shorter
        (["\t}", "}", ""], ["}", ""]),
    ],
}

def substitute_blocks(text, blocks):
    """Replace a sequence of context lines with another sequence.

    The blocks hold the content of the lines, without the diff prefix.
    """
    lines = text.split('\n')
    for old, new in blocks:
        for i in range(len(lines) - len(old) + 1):
            if all(lines[i + k] == ' ' + o for k, o in enumerate(old)):
                lines[i:i + len(old)] = [' ' + n for n in new]
                break
    return '\n'.join(lines)


def substitute(text, rules):
    """Replace the substrings of the context lines."""
    out = []
    for line in text.split('\n'):
        for old, new in rules:
            if old in line:
                line = line.replace(old, new)
        out.append(line)
    return '\n'.join(out)


# Hunks that have to be rewritten, not just renamed.
#
# The early console maps the splash framebuffer in the bootstrap tables. The
# sweet code put the entry in the FIRST V=P L2 table, which is the table of
# the L1 entry of the RAM. With 4 KiB pages an L1 entry covers 1 GiB, so the
# framebuffer is in an L1 entry of its own and its L2 table is a different
# one: the sweet code would have written the framebuffer over the mapping of
# the RAM. Look the L2 table up in the L1 table instead.
REPLACEMENTS = {
    '0010': [(
        "+\tand\t\tx12, x10, #(ARM_TT_L2_INDEX_MASK)\n"
        "+\tlsr\t\tx12, x12, #(ARM_TT_L2_SHIFT)\n"
        "+\tadd\t\tx13, x25, #(2 * PGBYTES)\n"
        "+\tstr\t\tx11, [x13, x12, lsl #TTE_SHIFT]",
        "+\t/*\n"
        "+\t * The L2 table of this GiB: with 4 KiB pages an L1 entry covers\n"
        "+\t * 1 GiB, so the framebuffer is not in the L1 entry of the RAM and\n"
        "+\t * its L2 table is not the first one. The V=P bootstrap mapping is\n"
        "+\t * VA=PA, so the physical address of the L2 table is its virtual\n"
        "+\t * address.\n"
        "+\t */\n"
        "+\tand\t\tx12, x10, #(ARM_TT_L1_INDEX_MASK)\n"
        "+\tlsr\t\tx12, x12, #(ARM_TT_L1_SHIFT)\n"
        "+\tldr\t\tx14, [x25, x12, lsl #TTE_SHIFT]\n"
        "+\tand\t\tx13, x14, #(ARM_TTE_TABLE_MASK)\n"
        "+\tand\t\tx12, x10, #(ARM_TT_L2_INDEX_MASK)\n"
        "+\tlsr\t\tx12, x12, #(ARM_TT_L2_SHIFT)\n"
        "+\tstr\t\tx11, [x13, x12, lsl #TTE_SHIFT]"),
    ],
}


def apply_replacements(text, replacements):
    """Replace the hunks that the renaming is not enough for."""
    for old, new in replacements:
        if old not in text:
            raise SystemExit('port-series: the hunk to replace was not found:\n' + old)
        text = text.replace(old, new)
    return text


def drop_lines(text, patterns):
    """Remove the context lines that match one of the patterns."""
    out = []
    for line in text.split('\n'):
        if line.startswith(' ') and any(p in line for p in patterns):
            continue
        out.append(line)
    return '\n'.join(out)


# The patches of the mondrian series that are written by hand and are not
# regenerated by this script.
HAND_WRITTEN_FILES = (
    '0001-mondrian-machine-config.patch',
    '0002-mondrian-master-config.patch',
    '0056-mondrian-comm-page-4k-pages.patch',
)


def split_groups(text):
    """Split a patch into its per-file groups.

    A group starts at a 'diff --git' line or, in the patches that have no
    such header, at a '--- ' line.
    """
    groups = []
    cur = []
    for line in text.split('\n'):
        if line.startswith('diff --git') or line.startswith('--- '):
            if cur:
                groups.append('\n'.join(cur))
            cur = [line]
        elif cur:
            cur.append(line)
    if cur:
        groups.append('\n'.join(cur))
    return groups


def filter_groups(text, patterns):
    """Keep only the file groups whose path matches one of the patterns."""
    groups = split_groups(text)
    kept = []
    for g in groups:
        header = g.split('\n', 1)[0]
        if any(p in header for p in patterns):
            kept.append(g)
    return '\n'.join(kept)


def port_text(text):
    """Apply the board renames."""
    for pat, rep in RENAMES:
        text = re.sub(pat, rep, text)
    return text


def out_name(name, number):
    """The name of the ported patch: the number of the mondrian series."""
    stem = re.sub(r'^\d{4}-', '', name)
    stem = re.sub(r'\bsweet\b', 'mondrian', stem)
    return f'{number:04d}-{stem}'


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('patch', nargs='*', help='patch number or name (in xnu/patches/)')
    ap.add_argument('--all', action='store_true', help='port every patch of the series')
    ap.add_argument('--out', default=MONDRIAN_SERIES, help='output directory')
    ap.add_argument('--start', type=int, default=3, help='first number of the output series')
    ap.add_argument('--dry-run', action='store_true', help='only report')
    a = ap.parse_args()

    all_patches = sorted(n for n in os.listdir(SWEET_SERIES) if n.endswith('.patch'))
    wanted = []
    if a.all:
        wanted = [n for n in all_patches
                  if n[:4] not in HARDWARE_PATCHES and n[:4] not in HAND_WRITTEN]
    else:
        for p in a.patch:
            match = [n for n in all_patches if n.startswith(p) or n[:4] == p]
            if not match:
                print(f'-- {p}: no such patch', file=sys.stderr)
                continue
            wanted += match
    if not wanted:
        ap.error('nothing to do: give a patch name or --all')

    os.makedirs(a.out, exist_ok=True)
    # remove the files of a previous run, but keep the hand written ones
    for f in sorted(os.listdir(a.out)):
        if not (f.endswith('.patch') or f.endswith('.sh')):
            continue
        if f in HAND_WRITTEN_FILES:
            continue
        os.remove(os.path.join(a.out, f))
    number = a.start
    for name in wanted:
        num = name[:4]
        if num in HAND_WRITTEN:
            print(f'-- {name}: ported by hand ({HAND_WRITTEN[num]})')
            continue
        if num in HARDWARE_PATCHES:
            print(f'-- {name}: hardware, not ported: {HARDWARE_PATCHES[num]}')
            continue
        with open(os.path.join(SWEET_SERIES, name), 'r', errors='surrogateescape') as f:
            text = f.read()
        if num in PARTIAL:
            text = filter_groups(text, PARTIAL[num])
            text = fix_hunk_counts(text)
            print(f'   (only the generic part: {", ".join(PARTIAL[num])})')
        if num in CONTEXT_BLOCKS:
            text = substitute_blocks(text, CONTEXT_BLOCKS[num])
            text = fix_hunk_counts(text)
        if num in REPLACEMENTS:
            text = apply_replacements(text, REPLACEMENTS[num])
            text = fix_hunk_counts(text)
        if num in DROP_LINES:
            text = drop_lines(text, DROP_LINES[num])
            text = fix_hunk_counts(text)
            print('   (context lines of the not yet ported hardware dropped)')
        text = port_text(text)
        dst = os.path.join(a.out, out_name(name, number))
        if not a.dry_run:
            with open(dst, 'w', errors='surrogateescape') as f:
                f.write(text if text.endswith('\n') else text + '\n')
        print(f'-- {name} -> {os.path.relpath(dst, REPO_ROOT)}')
        # the staging script of a patch keeps its number
        for extra in sorted(os.listdir(SWEET_SERIES)):
            if extra.startswith(num + '-') and extra.endswith('.sh'):
                with open(os.path.join(SWEET_SERIES, extra), 'r', errors='surrogateescape') as f:
                    sh_text = port_text(f.read())
                sh_dst = os.path.join(a.out, out_name(extra, number))
                if not a.dry_run:
                    with open(sh_dst, 'w', errors='surrogateescape') as f:
                        f.write(sh_text)
                print(f'   {extra} -> {os.path.relpath(sh_dst, REPO_ROOT)}')
        number += 1


if __name__ == '__main__':
    main()
