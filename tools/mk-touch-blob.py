#!/usr/bin/env python3
"""Build the touch blob the kernel reads from the area before the log ring.

The vendor ships two files: the firmware package (223744 bytes, six sections,
ISP first) and the sensor config group (goodix_cfg_group_m11a.bin, one
1488-byte group at the end of the wrapper). The vendor flashes the config
(type 4, 0x3e000) before the five firmware sections, so the blob lists it as
table entry 1: the kernel flashes entries in table order and the ISP's block
erase at 0x3e000 must not land after the firmware tail.

    mk-touch-blob.py FIRMWARE.bin CONFIG_GROUP.bin OUT.bin
"""

import struct
import sys

FW_HEADER = 512
FW_TABLE = 42
FW_ENTRY = 10
FW_MAX_SECTIONS = 47
CONFIG_TYPE = 4
CONFIG_ADDR = 0x3E000


def die(message):
    raise SystemExit("error: " + message)


def checksum16(data):
    if len(data) & 1:
        die("odd-length checksum payload")
    total = 0
    for i in range(0, len(data), 2):
        total += data[i] | (data[i + 1] << 8)
    return total & 0xFFFFFFFF


def load_config(path):
    """Return the config group (64-byte head plus body) from the group file.

    The wrapper before the group is a panel table whose layout is irrelevant
    here. The group head carries its own U8 checksum and its cfg_len, and in
    this file the group runs to the end, so both facts identify it.
    """
    blob = open(path, "rb").read()
    for off in range(len(blob) - 64, -1, -1):
        head = blob[off:off + 64]
        stored = head[62] | (head[63] << 8)
        if (sum(head[:62]) & 0xFFFF) != stored:
            continue
        cfg_len = head[59] | (head[60] << 8)
        if cfg_len and off + 64 + cfg_len == len(blob):
            return blob[off:]
    die("%s: no config group with a valid head checksum" % path)


def parse_sections(fw):
    count = fw[0x1D]
    if count > FW_MAX_SECTIONS:
        die("firmware claims %u sections" % count)
    sections = []
    off = FW_HEADER
    for i in range(count):
        entry = FW_TABLE + i * FW_ENTRY
        fw_type = fw[entry]
        size, addr = struct.unpack_from("<II", fw, entry + 1)
        sections.append((fw_type, size, addr, off))
        off += size
    if off != len(fw):
        die("sections add up to %u, package is %u" % (off, len(fw)))
    return count, sections


def main():
    if len(sys.argv) != 4:
        die("usage: mk-touch-blob.py FIRMWARE.bin CONFIG_GROUP.bin OUT.bin")
    fw_path, cfg_path, out_path = sys.argv[1:]

    fw = bytearray(open(fw_path, "rb").read())
    size, stored = struct.unpack_from("<II", fw, 0)
    if size + 8 != len(fw):
        die("%s: size %u does not match file %u" % (fw_path, size, len(fw)))
    if checksum16(fw[8:]) != stored:
        die("%s: bad package checksum" % fw_path)

    count, sections = parse_sections(fw)
    if count + 1 > FW_MAX_SECTIONS:
        die("no table room for the config section")

    config = load_config(cfg_path)
    # ISP first (it is the section the kernel loads to 0x23800), then the
    # config, then the firmware sections in their original order.
    isp = sections[0]
    order = [isp, (CONFIG_TYPE, len(config), CONFIG_ADDR, 0)] + sections[1:]
    if FW_TABLE + len(order) * FW_ENTRY > FW_HEADER:
        die("the reordered table does not fit in the header")

    out = bytearray(fw[:FW_HEADER])
    data_off = FW_HEADER
    for i, (fw_type, sec_size, addr, old_off) in enumerate(order):
        entry = FW_TABLE + i * FW_ENTRY
        out[entry] = fw_type
        struct.pack_into("<II", out, entry + 1, sec_size, addr)
        out[entry + 9] = 0
        if i == 1:
            out += config
        else:
            out += fw[old_off:old_off + sec_size]
        data_off += sec_size
    out[0x1D] = len(order)
    struct.pack_into("<I", out, 0, len(out) - 8)
    struct.pack_into("<I", out, 4, checksum16(out[8:]))

    # Re-read what the kernel will see, so a broken table never reaches flash.
    count2, sections2 = parse_sections(out)
    if count2 != len(order):
        die("repacked table does not read back")
    if sections2[1][:3] != (CONFIG_TYPE, len(config), CONFIG_ADDR) or len(sections2[1]) != 4:
        die("repacked config entry does not read back")
    if checksum16(out[8:]) != struct.unpack_from("<I", out, 4)[0]:
        die("repacked checksum does not read back")
    if data_off != len(out):
        die("section data is not contiguous")

    open(out_path, "wb").write(out)
    print("%u bytes, %u sections, config first at 0x%x" % (len(out), count2, CONFIG_ADDR))
    for i, (fw_type, sec_size, addr, off) in enumerate(sections2):
        print("  %u: type %u size %u addr 0x%x data 0x%x"
              % (i, fw_type, sec_size, addr, off))


if __name__ == "__main__":
    main()
