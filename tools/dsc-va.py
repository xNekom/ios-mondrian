#!/usr/bin/env python3
"""Name a dyld-cache address, and optionally disassemble around it.

    dsc-va.py CACHE_DIR ADDR [ADDR ...] [--slide HEX] [--disasm N]

A crash record from this port prints run-time addresses plus `slide 0x…`, so
pass the recorded values with `--slide` and this tool subtracts it (the kernel's
own comment: unslid = pc - slide).

Why not look the address up in an image table: the split cache's main header has
imagesCount 0 and every subcache carries its own path blob, so there is no single
table to read. A Mach-O header is page-aligned inside the mapping that holds it,
so the header is found by scanning backwards from the address and keeping the
candidate whose __TEXT segment covers it. That also separates images that share
an install name -- this cache holds two `/usr/lib/libc++abi.dylib` (one for
DriverKit, one for iOS), and `tools/dsc-image.py` takes the first by name.

The address printed is the offset inside __TEXT, which is what a rebuilt image's
disassembly uses: `tools/dsc-image.py CACHE libc++abi.dylib out` writes a Mach-O
whose vmaddrs are the cache's, so `llvm-objdump -d --start-address=…` lines up.
"""
import argparse
import glob
import importlib.util
import mmap
import os
import struct
import subprocess
import sys

MH_MAGIC_64 = b"\xcf\xfa\xed\xfe"
LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xd
SCAN_BACK = 16 << 20


def load_cache_module(path):
    spec = importlib.util.spec_from_file_location("dsc_image", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def open_maps(directory):
    """(vmaddr, size, mmap, file name, file offset) for every mapping."""
    maps = []
    for path in sorted(glob.glob(os.path.join(directory, "dyld_shared_cache*"))):
        if path.endswith((".symbols", ".bad", ".map")):
            continue
        try:
            with open(path, "rb") as f:
                image = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        except OSError:
            continue
        if image[0:6] != b"dyld_v":
            image.close()
            continue
        offset, count = struct.unpack_from("<II", image, 0x10)
        for i in range(count):
            vmaddr, size, fileoffset = struct.unpack_from("<QQQ", image, offset + i * 32)
            maps.append((vmaddr, size, image, os.path.basename(path), fileoffset))
    return maps


def identity(image, at):
    if at < 0 or at + 32 > len(image):
        return None
    ncmds, sizeofcmds = struct.unpack_from("<II", image, at + 16)
    if not (0 < ncmds < 400 and 0 < sizeofcmds < 0x200000
            and at + 32 + sizeofcmds <= len(image)):
        return None
    off, text, name = at + 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", image, off)
        if size < 8 or size > 0x20000 or off + size > len(image):
            return None
        if cmd == LC_SEGMENT_64:
            seg = bytes(image[off + 8:off + 24]).split(b"\0")[0].decode("ascii", "replace")
            vmaddr, vmsize = struct.unpack_from("<QQ", image, off + 24)
            if seg == "__TEXT":
                text = (vmaddr, vmsize)
        elif cmd == LC_ID_DYLIB:
            noff = struct.unpack_from("<I", image, off + 8)[0]
            raw = bytes(image[off + noff:off + noff + 400])
            end = raw.find(b"\0")
            if end > 0:
                name = raw[:end].decode("ascii", "replace")
        off += size
    if name is None or text is None:
        return None
    return name, text


def owner(maps, va):
    for vmaddr, size, image, base, fileoffset in maps:
        if not (vmaddr <= va < vmaddr + size):
            continue
        at = fileoffset + (va - vmaddr)
        low = max(0, at - SCAN_BACK)
        pos = image.rfind(MH_MAGIC_64, low, at)
        best = None
        while pos >= 0:
            hit = identity(image, pos)
            if hit is not None:
                name, (tv, tsz) = hit
                if tv <= va < tv + tsz and (best is None or tv > best[1][0]):
                    best = (name, (tv, tsz))
            pos = image.rfind(MH_MAGIC_64, low, pos)
        if best is not None:
            return best[0], best[1][0], base
    return None, None, None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("cache")
    parser.add_argument("addresses", nargs="+")
    parser.add_argument("--slide", default=None,
                        help="subtract this from every address (a record's `slide 0x...`)")
    parser.add_argument("--disasm", type=int, default=0, metavar="N",
                        help="disassemble N instructions from the address")
    parser.add_argument("--objdump", default="llvm-objdump")
    args = parser.parse_args()

    maps = open_maps(args.cache)
    slide = int(args.slide, 0) if args.slide else 0
    rebuilt = {}
    for arg in args.addresses:
        va = int(arg, 0) - slide
        name, text, base = owner(maps, va)
        if name is None:
            print("%#x -> nowhere (%s)" % (va, base or "below every mapping"))
            continue
        print("%#x -> %s + %#x  [__TEXT %#x]" % (va, name, va - text, text))
        if not args.disasm:
            continue
        path = rebuilt.get(name)
        if path is None:
            tool = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dsc-image.py")
            path = os.path.join(args.cache, os.path.basename(name).replace(".", "_") + ".va")
            module = load_cache_module(tool)
            cache = module.Cache(args.cache)
            where = None
            for vmaddr, size, index, fileoffset in cache.maps:
                if vmaddr <= text < vmaddr + size:
                    where = (index, fileoffset + (text - vmaddr))
                    break
            if where is None:
                print("   cannot pin the header for a rebuild")
                continue
            commands = module.Cache._commands(cache.files[where[0]], where[1])
            cache.header_of = lambda wanted: (where, commands)
            if not module.rebuild(cache, "pinned", path):
                print("   rebuild failed")
                continue
            rebuilt[name] = path
        out = subprocess.run([args.objdump, "-d", "--no-show-raw-insn",
                              "--start-address=%#x" % (va - 0x20),
                              "--stop-address=%#x" % (va + 8 * args.disasm),
                              path], capture_output=True, text=True)
        for line in out.stdout.splitlines():
            if line.strip() and "Disassembly" not in line:
                print("   " + line.strip())


if __name__ == "__main__":
    main()
