#!/usr/bin/env python3
"""Re-derive the CoreAnimation numbers in mondrian_offsets.h from a Mach-O image.

The three numbers the injector needs are not exported API, so they are found by symbol:

  MONDIAN_CA_GLESCONTEXT_VTABLE       __ZTVN2CA4OGL11GLESContextE
  MONDIAN_CA_FN_FUNCTION_SUPPORTED    CA::OGL::GLContext::function_supported() const
  MONDIAN_CA_FN_FUNCTION_UNIFORM      CA::OGL::GLContext::function_uniform(unsigned, ...)

Given QuartzCore out of the dyld shared cache (the image's own vmaddrs are cache addresses, so
`vmaddr - --base` is exactly what mondrian_offsets.h wants), this reads its symbol table, finds
the vtable and the two methods, and reads the vtable to find the two slots that hold them -- the
slot offsets change with the class layout, so they are measured, not assumed.

    ipsw dyld extract dyld_shared_cache_arm64e \\
        /System/Library/PrivateFrameworks/QuartzCore.framework/QuartzCore -o /tmp/qc
    tools/gpu/mondrian-offsets.py /tmp/qc/QuartzCore/QuartzCore            # print what it found
    tools/gpu/mondrian-offsets.py /tmp/qc/QuartzCore/QuartzCore -o tools/gpu/mondrian_offsets.h

The same works on any image with a vtable, which is how the reader is tested here:

    clang++ -shared -o /tmp/t.dylib t.cpp && tools/gpu/mondrian-offsets.py /tmp/t.dylib

A dyld cache holds local symbols in a separate .symbols file; an image extracted without it has
no symbol table and this tool says so. `ipsw dyld symaddr <cache> <name>` answers the same
question for one address (tools/ios-crash.py uses the same call for crash PCs).
"""
import argparse
import os
import re
import struct
import subprocess
import sys

CPU_ARM64 = 0x0100000C
CPU_ARM64E = 0x0100000C | 0x02000000
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

DEFAULT_VTABLE = "GLESContext"
DEFAULT_METHODS = ("function_supported", "function_uniform")
# How far into a vtable to look for the methods: CoreAnimation's classes are large.
VTABLE_WINDOW = 0x2000


class MachO:
    """The little of a 64-bit Mach-O this needs: the symbol table and the segments."""

    def __init__(self, path):
        self.data = open(path, "rb").read()
        self.slices = self._slices()
        offset, end = self._slice_for_arm64()
        self.offset = offset
        self.size = end - offset
        self.segments = []
        self.symbols = {}
        self._load(offset)

    def _slices(self):
        if len(self.data) < 8:
            sys.exit("not a Mach-O file")
        magic = struct.unpack_from(">I", self.data, 0)[0]
        if magic not in (FAT_MAGIC, FAT_MAGIC_64):
            return [(0, len(self.data))]
        wide = magic == FAT_MAGIC_64
        count = struct.unpack_from(">I", self.data, 4)[0]
        at = 8
        slices = []
        for _ in range(count):
            if wide:
                cpu, _sub, offset, size = struct.unpack_from(">iiQQ", self.data, at)
                at += 32
            else:
                cpu, _sub, offset, size = struct.unpack_from(">iiII", self.data, at)
                at += 20
            slices.append((offset, offset + size, cpu))
        return slices

    def _slice_for_arm64(self):
        for entry in self.slices:
            if len(entry) == 3:
                offset, end, cpu = entry
                if cpu in (CPU_ARM64, CPU_ARM64E):
                    return offset, end
        if len(self.slices[0]) == 3:
            sys.exit("no arm64 slice in this file")
        return self.slices[0]

    def _load(self, base):
        magic, _cpu, _sub, _filetype, commands, _size, _flags = struct.unpack_from("<IiiIIII", self.data, base)
        if magic != MH_MAGIC_64:
            sys.exit("not a thin 64-bit little-endian Mach-O")
        at = base + 32
        symtab = None
        for _ in range(commands):
            command, length = struct.unpack_from("<II", self.data, at)
            if command == LC_SEGMENT_64:
                name = self.data[at + 8:at + 24].split(b"\0")[0].decode(errors="replace")
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", self.data, at + 24)
                self.segments.append((name, vmaddr, vmsize, fileoff, filesize))
            elif command == LC_SYMTAB:
                symtab = struct.unpack_from("<IIII", self.data, at + 8)
            at += length
        if symtab is None:
            sys.exit("no LC_SYMTAB: the image has no symbol table (extract the cache with its "
                     ".symbols file, or name one address with `ipsw dyld symaddr`)")
        symoff, nsyms, stroff, strsize = symtab
        strings = self.data[base + stroff:base + stroff + strsize]
        for index in range(nsyms):
            entry = base + symoff + index * 16
            name_at, n_type, _sect, _desc, value = struct.unpack_from("<IBBHQ", self.data, entry)
            if value == 0 or n_type & 0xE0 != 0x00:      # N_STAB entries are not symbols
                continue
            end = strings.find(b"\0", name_at)
            name = strings[name_at:end].decode(errors="replace")
            if name:
                self.symbols.setdefault(name, value)

    def read(self, address, size):
        for _name, vmaddr, vmsize, fileoff, filesize in self.segments:
            if vmaddr <= address and address + size <= vmaddr + min(vmsize, filesize):
                at = self.offset + fileoff + (address - vmaddr)
                return self.data[at:at + size]
        return None


def demangle_name(name):
    """Enough of the Itanium mangling to recognise the class and method: not a demangler."""
    return re.sub(r"^_+Z(TV|TI|NK|N|St)?", "", name)


def dump_words(dsc, address, size):
    """The vtable words as the cache holds them.

    An extracted image can lose the pointers that live in the cache's
    __AUTH_CONST region, so the measurement is taken from the cache itself.
    """
    result = subprocess.run(["ipsw", "dyld", "dump", dsc, f"{address:#x}",
                             "-a", "-c", str(size // 8)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    words = []
    for line in result.stdout.split():
        try:
            words.append(int(line, 16))
        except ValueError:
            return None
    return words if len(words) == size // 8 else None


def find_symbols(macho, pattern):
    """[(name, address)] whose symbol name matches, shortest name first."""
    return [(name, macho.symbols[name]) for name in
            sorted((name for name in macho.symbols if re.search(pattern, name)), key=len)]


def find_symbol(macho, pattern, in_table=None):
    """The first symbol for a pattern; with in_table, the first one whose address is in it."""
    for name, address in find_symbols(macho, pattern):
        if in_table is None or address in in_table:
            return name, address
    return None, None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", help="a thin arm64 Mach-O (e.g. QuartzCore out of the cache)")
    ap.add_argument("--base", default="0x180000000", help="the cache's base address (default 0x180000000)")
    ap.add_argument("--vtable", default=DEFAULT_VTABLE, help=f"vtable symbol to look for (default {DEFAULT_VTABLE})")
    ap.add_argument("--method", action="append", help="method symbol to look for (default: the two GLContext methods)")
    ap.add_argument("--dsc", help="read the vtable from this dyld shared cache instead of the "
                    "image (required for builds whose vtable lives in __AUTH_CONST)")
    ap.add_argument("-o", "--output", help="rewrite the numbers in this mondrian_offsets.h")
    args = ap.parse_args()

    base = int(args.base, 0)
    macho = MachO(args.image)
    methods = args.method or list(DEFAULT_METHODS)

    vtable_name, vtable_address = find_symbol(macho, r"^_*ZTV.*" + re.escape(args.vtable))
    if vtable_address is None:
        sys.exit(f"no vtable symbol for {args.vtable} in {args.image}")
    print(f"vtable   {vtable_address - base:#x}  {vtable_name}")

    # The vtable itself: offset-to-top, the typeinfo pointer, then one entry per virtual method.
    if args.dsc:
        entries = dump_words(args.dsc, vtable_address, VTABLE_WINDOW)
        if entries is None:
            sys.exit(f"could not read the vtable at {vtable_address:#x} from {args.dsc}")
    else:
        window = macho.read(vtable_address, VTABLE_WINDOW)
        if window is None:
            sys.exit("the vtable is not in a file-backed segment")
        entries = [struct.unpack_from("<Q", window, at)[0] for at in range(0, len(window), 8)]

    found, slots = {}, {}
    for method in methods:
        # A method can exist more than once in a family (base class and override): the one the
        # vtable actually holds is the one CoreAnimation calls.
        name, address = find_symbol(macho, re.escape(method), in_table=set(entries))
        if address is None:
            name, address = find_symbol(macho, re.escape(method))
            if address is None:
                sys.exit(f"no symbol for {method} in {args.image}")
            sys.exit(f"{name} is not in the vtable at {vtable_address - base:#x}: wrong image or base")
        at = entries.index(address)
        found[method] = address
        slots[method] = at * 8 - 0x10               # byte offset from the first entry
        print(f"method   {address - base:#x}  {name}")
        print(f"slot     {slots[method]:#x}  {method} is vtable entry {at - 2}")

    values = {
        "MONDIAN_CA_GLESCONTEXT_VTABLE": vtable_address - base,
        "MONDIAN_CA_VSLOT_FUNCTION_SUPPORTED": slots["function_supported"],
        "MONDIAN_CA_VSLOT_FUNCTION_UNIFORM": slots["function_uniform"],
        "MONDIAN_CA_FN_FUNCTION_SUPPORTED": found["function_supported"] - base,
        "MONDIAN_CA_FN_FUNCTION_UNIFORM": found["function_uniform"] - base,
    }
    if args.output:
        text = open(args.output).read()
        for macro, value in values.items():
            text, count = re.subn(rf"(#define\s+{macro}\s+)(0x[0-9a-fA-F]+|\d+)(UL|U|L)?",
                                  lambda m: f"{m.group(1)}{value:#x}", text)
            if count != 1:
                sys.exit(f"{args.output}: {macro} is not there once ({count} times)")
        open(args.output, "w").write(text)
        print(f"{args.output}: rewritten")
    else:
        for macro, value in values.items():
            print(f"#define {macro:<38} {value:#x}")


if __name__ == "__main__":
    main()
