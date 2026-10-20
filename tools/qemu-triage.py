#!/usr/bin/env python3
"""Summarise what a QEMU run did: the first exception and the symbol.

  tools/qemu-triage.py OUTDIR [KERNEL]

Reads the qemu.log of a run of tools/qemu-ios.py, finds the first
exception, decodes the ESR and says which function the kernel was in
(with --kernel, the unstripped Mach-O, the symbol is resolved).

  ESR 0x21  = instruction abort from a lower exception level
  ISS 0x02000004 = permission fault, level 1, execute never (SCTLR.x = 0)
"""
import os
import re
import subprocess
import sys

ESR_NAMES = {
    0x20: "instruction abort from a lower level",
    0x21: "instruction abort, upper level",
    0x24: "data abort from a lower level",
    0x25: "data abort, upper level",
    0x2c: "prefetch abort, upper level",
}


def decode(ec, iss):
    out = [ESR_NAMES.get(ec, f"exception {ec:#x}")]
    if ec in (0x20, 0x21, 0x2c):
        if iss & (1 << 25):
            out.append(f"permission fault, level {(iss >> 2) & 3}")
            out.append("execute never (SCTLR.x = 0)" if not (iss & 1)
                       else "unprivileged never (SCTLR.U = 0)")
        else:
            out.append(f"translation fault, level {(iss >> 2) & 3}")
    else:
        out.append(f"DFSC {(iss >> 2) & 0x3f:#x}")
    return ", ".join(out)


def symbols(kernel):
    """The sorted symbol table of the kernel: address -> name."""
    out = []
    nm = os.environ.get('LLVM_NM', 'llvm-nm')
    p = subprocess.run([nm, '-n', kernel], capture_output=True, text=True)
    if p.returncode:
        nm = 'aarch64-linux-gnu-nm'
        p = subprocess.run([nm, '-n', kernel], capture_output=True, text=True)
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            try:
                out.append((int(parts[0], 16), parts[2]))
            except ValueError:
                pass
    out.sort()
    return out


def lookup(syms, addr):
    if not syms:
        return None
    lo, hi = 0, len(syms) - 1
    best = None
    while lo <= hi:
        mid = (lo + hi) // 2
        if syms[mid][0] <= addr:
            best = syms[mid]
            lo = mid + 1
        else:
            hi = mid - 1
    return best


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    outdir = sys.argv[1]
    kernel = sys.argv[2] if len(sys.argv) > 2 else None
    log = os.path.join(outdir, 'qemu.log')
    if not os.path.exists(log):
        raise SystemExit(f'{log} not found')

    syms = symbols(kernel) if kernel else []
    with open(log, errors='replace') as f:
        for line in f:
            if 'Taking exception' not in line:
                continue
            block = [line]
            for _ in range(6):
                block.append(f.readline())
            text = ''.join(block)
            esr = re.search(r'ESR (0x[0-9a-f]+)/(0x[0-9a-f]+)', text)
            far = re.search(r'FAR (0x[0-9a-f]+)', text)
            print('first exception:')
            print('  ', line.strip())
            if esr:
                ec = int(esr.group(1), 16)
                iss = int(esr.group(2), 16)
                print('   ESR', esr.group(1), '/', esr.group(2), '->', decode(ec, iss))
            if far:
                addr = int(far.group(1), 16)
                print('   FAR', far.group(1))
                s = lookup(syms, addr)
                if s:
                    print(f'   symbol {s[1]} (+{addr - s[0]:#x})')
            return 0
    print('no exception in the log')
    return 0


if __name__ == '__main__':
    sys.exit(main())
