#!/usr/bin/env python3
"""Generate mondrian_cp_profile.h from an open gen7 vendor driver.

    tools/gen-cp-profile-open.py VENDOR_DIR OUT.h

tools/gen-cp-profile.py takes the vendor's `PongAdrenoCpProfile.h`, a local
build input that only ships in Nothing's non-public tree. The same four tables
are in Qualcomm's open KGSL driver for the same GPU, so this reads them from
there instead (GPL-2.0-only, `NothingOSS/android_kernel_msm-5.10_nothing_sm8475`,
path `drivers/gpu/msm/`):

    adreno-gpulist.h  the a730 entry (`adreno_gpu_core_gen7_0_0`, chipid
                      0x07030000, `a730_sqe.fw`) and the tables it points at:
                      `gen7_0_0_{gbif,hwcg,protected}_regs`
    adreno_gen7.c     `gen7_pwrup_reglist` and `gen7_ifpc_pwrup_reglist`, the
                      registers the CP restores after a power collapse
    gen7_reg.h        the `GEN7_*` register offsets the tables name

The output has the shape `mondrian_gpu.c` expects (and that the vendored
generator produces): the `GEN7_*` numbers plus `mondrian_cp_gbif`,
`mondrian_cp_hwcg`, `mondrian_cp_protect` (each [n][2] of offset, value) and
`mondrian_cp_restore` (offsets), with their `_count` macros.

It is not committed: the register numbers and sequences are the vendor's, and
the tree picks the header up with __has_include.
"""

import argparse
import re
import sys
from pathlib import Path

A730_CORE = "adreno_gpu_core_gen7_0_0"
TABLES = ("gbif", "hwcg", "protected_regs")
RE_DEFINE = re.compile(r"^#define\s+(GEN7_[A-Za-z0-9_]+)\s+(\S+)\s*$")


def read_defines(path):
    """GEN7_* name -> int, for the plain numeric defines."""
    out = {}
    for line in path.read_text().splitlines():
        m = RE_DEFINE.match(line)
        if not m:
            continue
        try:
            out[m.group(1)] = int(m.group(2), 0)
        except ValueError:
            continue            # an expression, or another macro
    return out


def resolve(expr, defines, where):
    """'GEN7_X + 3' -> int."""
    parts = [p.strip() for p in expr.split("+")]
    total = 0
    for part in parts:
        if part in defines:
            total += defines[part]
            continue
        try:
            total += int(part, 0)
        except ValueError:
            sys.exit(f"error: {where}: cannot resolve {part!r} in {expr!r}")
    return total


def block(text, opening, where):
    """The text between `opening ... {` and the matching `};`."""
    at = text.find(opening)
    if at < 0:
        sys.exit(f"error: {where}: no {opening!r}")
    start = text.index("{", at)
    end = text.index("};", start)
    return text[start + 1:end]


def pairs(table, defines, where):
    out = []
    for line in table.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        fields = [f.strip() for f in line.strip("{},").split(",")]
        if len(fields) < 2:
            continue
        out.append((resolve(fields[0], defines, where), int(fields[1], 0)))
    return out


def protected(table, defines, where):
    """The same arithmetic gen7_protect_init() does."""
    out = []
    for line in table.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        fields = [f.strip() for f in line.strip("{},").split(",")]
        if len(fields) < 4:
            continue
        reg = resolve(fields[0], defines, where)
        start, end, noaccess = (int(f, 0) for f in fields[1:4])
        value = (start & 0x3ffff) | (((end - start) & 0x1fff) << 18)
        if noaccess:
            value |= 1 << 31
        out.append((reg, value))
    return out


def registers(listing, defines, where):
    return [resolve(line.strip().rstrip(","), defines, where)
            for line in listing.splitlines()
            if line.strip().startswith("GEN7_")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vendor", help="directory with adreno-gpulist.h, adreno_gen7.c, gen7_reg.h")
    ap.add_argument("out", help="mondrian_cp_profile.h to write")
    args = ap.parse_args()

    vendor = Path(args.vendor)
    defines = read_defines(vendor / "gen7_reg.h")
    if not defines:
        sys.exit(f"error: no GEN7_* defines in {vendor / 'gen7_reg.h'}")

    core = (vendor / "adreno-gpulist.h").read_text()
    at = core.find(A730_CORE + " = {")
    if at < 0:
        sys.exit(f"error: no {A730_CORE} in adreno-gpulist.h")
    entry = core[at:core.index("\n};", at)]
    if "a730_sqe.fw" not in entry:
        sys.exit("error: that entry is not the a730 (no a730_sqe.fw)")
    chosen = {}
    for table in TABLES:
        m = re.search(rf"\.{table}\s*=\s*(\w+)", entry)
        if not m:
            sys.exit(f"error: the a730 entry has no .{table}")
        chosen[table] = m.group(1)

    tables = {}
    for table in ("gbif", "hwcg"):
        text = block(core, chosen[table] + "[] = {", table)
        tables[table] = pairs(text, defines, table)
    tables["protect"] = protected(
        block(core, chosen["protected_regs"] + "[] = {", "protected_regs"),
        defines, "protected_regs")

    gen7 = (vendor / "adreno_gen7.c").read_text()
    restore = []
    for name in ("gen7_pwrup_reglist", "gen7_ifpc_pwrup_reglist"):
        for reg in registers(block(gen7, name + "[] = {", name), defines, name):
            if reg not in restore:
                restore.append(reg)

    lines = [
        "/* generated by tools/gen-cp-profile-open.py; do not commit",
        " * source: Qualcomm's open gen7 KGSL driver (GPL-2.0-only)",
        f" * core: {A730_CORE} (a730, chipid 0x07030000) */",
        "#ifndef MONDRIAN_CP_PROFILE_H",
        "#define MONDRIAN_CP_PROFILE_H",
        "#include <stdint.h>",
        "",
    ]
    for name in sorted(defines):
        lines.append(f"#define {name} {defines[name]:#x}")
    lines.append("")
    for table in ("gbif", "hwcg", "protect"):
        lines.append(f"static const uint32_t mondrian_cp_{table}[][2] = {{")
        for reg, value in tables[table]:
            lines.append(f"\t{{ {reg:#x}, {value:#x} }},")
        lines.append("};")
        lines.append(f"#define mondrian_cp_{table}_count "
                     f"(sizeof(mondrian_cp_{table}) / sizeof(mondrian_cp_{table}[0]))")
        lines.append("")
    lines.append("static const uint32_t mondrian_cp_restore[] = {")
    for reg in restore:
        lines.append(f"\t{reg:#x},")
    lines.append("};")
    lines.append("#define mondrian_cp_restore_count "
                 "(sizeof(mondrian_cp_restore) / sizeof(mondrian_cp_restore[0]))")
    lines.append("#endif")

    Path(args.out).write_text("\n".join(lines) + "\n")
    print(f"{args.out}: gbif {len(tables['gbif'])}, hwcg {len(tables['hwcg'])}, "
          f"protect {len(tables['protect'])}, restore {len(restore)}, "
          f"{len(defines)} GEN7_* defines")


if __name__ == "__main__":
    main()
