#!/usr/bin/env python3
"""Rebuild one image out of an iOS dyld shared cache, so it can be read as a Mach-O.

    dsc-image.py CACHE_DIR IMAGE_NAME [OUT]

CACHE_DIR holds dyld_shared_cache_arm64 and its .NN subcaches. IMAGE_NAME is a
substring of the image's install name, e.g. SpringBoardHome. OUT defaults to
IMAGE_NAME.arm64 in CACHE_DIR.

Why not `ipsw dyld extract`: every `ipsw dyld` subcommand opens the cache's
companion .symbols file first, and on this workstation both that file and the
main cache are truncated copies -- the extract fails before reading anything, with
`unexpected EOF`, `file's UUID is empty` or `... shorter than its fixed prefix`.
The subcaches themselves are intact, and they are enough.

How it works: each subcache file carries a header with a mapping table
(vmaddr, size, file offset). An image's Mach-O header is found by its
LC_ID_DYLIB string; each LC_SEGMENT_64 then names the vmaddr range of that
segment, and the mapping table says which file holds that range and where. The
segments are copied out in order, __LINKEDIT is dropped (in a shared cache it is
one region shared by every image, hundreds of megabytes), and every section's
file offset is rebased onto its new segment.

The result is a valid thin arm64 Mach-O whose vmaddrs are the cache's. It has no
symbol table, so only Objective-C metadata, strings and the code are usable --
which is what reading a framework needs.
"""
import glob
import mmap
import os
import struct
import sys

MH_MAGIC_64 = b"\xcf\xfa\xed\xfe"
LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xd
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xb
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
PAGE = 0x4000
# commands whose payload lives in the shared __LINKEDIT, which a rebuilt image does not
# carry: symbol and dynamic-symbol tables, dyld info, function starts, data-in-code, the
# code signature, split-segment info, and the exports/chained-fixup tries
DROPPED = {
    0x2,            # LC_SYMTAB
    0xb,            # LC_DYSYMTAB
    0x22,           # LC_DYLD_INFO
    0x80000022,     # LC_DYLD_INFO_ONLY
    0x26,           # LC_FUNCTION_STARTS
    0x29,           # LC_DATA_IN_CODE
    0x1d,           # LC_CODE_SIGNATURE
    0x1e,           # LC_SEGMENT_SPLIT_INFO
    0x80000033,     # LC_DYLD_EXPORTS_TRIE
    0x80000034,     # LC_DYLD_CHAINED_FIXUPS
}


class Cache:
    """Every subcache file, mapped, plus the vmaddr to file mapping each one declares."""

    def __init__(self, directory):
        self.files = []
        self.maps = []          # (vmaddr, size, index, file offset)
        for path in sorted(glob.glob(os.path.join(directory, "dyld_shared_cache*"))):
            if path.endswith(".symbols") or path.endswith(".bad") or path.endswith(".map"):
                continue
            try:
                with open(path, "rb") as f:
                    image = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            except OSError:
                continue
            if image[0:6] != b"dyld_v":
                image.close()
                continue
            index = len(self.files)
            self.files.append(image)
            offset, count = struct.unpack_from("<II", image, 0x10)
            for i in range(count):
                at = offset + i * 32
                vmaddr, size, fileoffset = struct.unpack_from("<QQQ", image, at)
                self.maps.append((vmaddr, size, index, fileoffset))

    def read(self, vmaddr, size):
        for vmaddr_at, length, index, fileoffset in self.maps:
            if vmaddr_at <= vmaddr and vmaddr + size <= vmaddr_at + length:
                start = fileoffset + (vmaddr - vmaddr_at)
                return self.files[index][start:start + size]
        return None

    def header_of(self, name):
        needle = name.encode() + b"\0"
        for index, image in enumerate(self.files):
            at = image.find(needle)
            while at >= 0:
                for header in self._headers_before(image, at):
                    commands = self._commands(image, header)
                    if commands is None:
                        continue
                    for command in commands:
                        if struct.unpack_from("<I", command, 0)[0] != LC_ID_DYLIB:
                            continue
                        nameoff = struct.unpack_from("<I", command, 8)[0]
                        if needle in bytes(command[nameoff:]):
                            return (index, header), commands
                at = image.find(needle, at + 1)
        return None, None

    @staticmethod
    def _headers_before(image, at, limit=0x4000):
        pos = image.find(MH_MAGIC_64, max(0, at - limit), at)
        while pos >= 0:
            yield pos
            pos = image.find(MH_MAGIC_64, pos + 1, at)

    @staticmethod
    def _commands(image, header):
        ncmds, sizeofcmds = struct.unpack_from("<II", image, header + 16)
        if not (0 < ncmds < 400 and 0 < sizeofcmds < 0x200000):
            return None
        commands, off = [], header + 32
        for _ in range(ncmds):
            command, cmdsize = struct.unpack_from("<II", image, off)
            if cmdsize < 8 or cmdsize > 0x20000 or off + cmdsize > len(image):
                return None
            commands.append(bytearray(image[off:off + cmdsize]))
            off += cmdsize
        return commands


def rebuild(cache, name, out):
    where, commands = cache.header_of(name)
    if commands is None:
        return False
    index, header = where
    head = cache.files[index][header:header + 32]

    places, cursor = [], 0
    for command in commands:
        if struct.unpack_from("<I", command, 0)[0] != LC_SEGMENT_64:
            continue
        segname = bytes(command[8:24]).split(b"\0")[0].decode("ascii", "replace")
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", command, 24)
        if segname == "__TEXT":
            cursor = 0
        else:
            cursor = (cursor + PAGE - 1) & ~(PAGE - 1)
        places.append([command, segname, vmaddr, vmsize, filesize, cursor])
        if segname != "__LINKEDIT":
            cursor += filesize

    image = bytearray(cursor)
    for command, segname, vmaddr, vmsize, filesize, new in places:
        if segname == "__LINKEDIT":
            struct.pack_into("<QQQQ", command, 24, vmaddr, 0, 0, 0)
            continue
        chunk = cache.read(vmaddr, filesize)
        if chunk is None:
            raise SystemExit("no mapping covers %s at %#x" % (segname, vmaddr))
        image[new:new + len(chunk)] = chunk
        struct.pack_into("<QQQQ", command, 24, vmaddr, vmsize, new, filesize)
        for i in range(struct.unpack_from("<I", command, 64)[0]):
            section = 72 + i * 80
            addr = struct.unpack_from("<Q", command, section + 32)[0]
            if vmaddr <= addr <= vmaddr + filesize:
                struct.pack_into("<I", command, section + 48, new + (addr - vmaddr))
    # every command that points into the shared __LINKEDIT loses its target, so they go
    commands = [c for c in commands if struct.unpack_from("<I", c, 0)[0] not in DROPPED]
    head = bytearray(head)
    struct.pack_into("<II", head, 16, len(commands), sum(len(c) for c in commands))
    body = bytearray()
    for command in commands:
        body += command
    image[0:32] = head
    image[32:32 + len(body)] = body
    with open(out, "wb") as f:
        f.write(image)
    return True


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip().splitlines()[0])
    directory, name = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else os.path.join(directory, name + ".arm64")
    cache = Cache(directory)
    if not cache.files:
        sys.exit("no dyld shared cache in %s" % directory)
    if not rebuild(cache, name, out):
        sys.exit("no image named %r in %s" % (name, directory))
    print("wrote %s (%d bytes)" % (out, os.path.getsize(out)))


if __name__ == "__main__":
    main()
