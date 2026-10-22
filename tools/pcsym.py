#!/usr/bin/env python3
"""Name the kernel symbol at a PC (or list the symbols around it).

The phone's beacon prints the interrupted PC; this turns that address into
a symbol using the CI kernel's symbol table.

    tools/pcsym.py 0xfffffff007123456 --kernel /tmp/mk67/xnu-kernel-mondrian/kernel.development.mondrian
    tools/pcsym.py --kernel ... --list 0xfffffff007123456
"""
import argparse
import bisect
import os
import re
import subprocess
import sys

DEFAULT_KERNEL = "/tmp/mk67/xnu-kernel-mondrian/kernel.development.mondrian"


def symbols(kernel):
    """[(address, name)] sorted by address."""
    nm = None
    for cand in ("/opt/homebrew/opt/llvm/bin/llvm-nm", "llvm-nm", "nm"):
        try:
            subprocess.run([cand, "--version"], capture_output=True, check=True)
            nm = cand
            break
        except (OSError, subprocess.CalledProcessError):
            continue
    if nm is None:
        sys.exit("no llvm-nm found")
    out = subprocess.run([nm, "-n", kernel], capture_output=True, text=True).stdout
    syms = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and re.fullmatch(r"[0-9a-fA-F]+", parts[0]):
            syms.append((int(parts[0], 16), parts[2]))
    return syms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pc", nargs="*", help="addresses to resolve")
    ap.add_argument("--kernel", default=DEFAULT_KERNEL)
    ap.add_argument("--list", action="store_true", help="list the symbols around the address")
    args = ap.parse_args()

    if not os.path.exists(args.kernel):
        sys.exit(f"no kernel at {args.kernel}")
    syms = symbols(args.kernel)
    if not syms:
        sys.exit("no symbols in the kernel")
    addrs = [a for a, _ in syms]

    for pc in args.pc:
        v = int(pc, 16)
        i = bisect.bisect_right(addrs, v) - 1
        if i < 0:
            print(f"{pc}: below the first symbol")
            continue
        a, name = syms[i]
        print(f"{pc}: {name} + 0x{v - a:x}  ({name} at 0x{a:x})")
        if args.list:
            for j in range(max(0, i - 3), min(len(syms), i + 4)):
                mark = "->" if j == i else "  "
                print(f"  {mark} 0x{syms[j][0]:x} {syms[j][1]}")


if __name__ == "__main__":
    main()
