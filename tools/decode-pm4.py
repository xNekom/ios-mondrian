#!/usr/bin/env python3
"""Decode the ring dwords that 0323/0324 print around a stuck cursor.

The driver prints them from the fence gate (`MONDRIAN GPU: rtail <offset> ...`),
32 or 128 dwords behind the cursor, because reading a parked CP's registers is
what froze boots before. This turns that hex back into packets so the one the CP
did not execute has a name. Usage:

    tools/decode-pm4.py usb-ring.txt
"""
import re
import sys

TYPE7_NAMES = {
    0x10: "CP_NOP",
    0x12: "CP_SEMAPHORE?",
    0x15: "CP_WAIT_FOR_IDLE",
    0x16: "CP_WAIT_REG_MEM",
    0x19: "CP_REG_RMW",
    0x21: "CP_REG_TO_SCRATCH",
    0x22: "CP_SCRATCH_TO_REG",
    0x26: "CP_REG_TO_MEM",
    0x2c: "CP_SAVE_REG",
    0x2d: "CP_SAVE_CTX",
    0x30: "CP_RESTORE_CTX",
    0x31: "CP_RESTORE_CTX_MORE",
    0x32: "CP_SCRATCH_TO_IB",
    0x36: "CP_SET_DRAW_STATE",
    0x37: "CP_INDIRECT_BUFFER_PFD",
    0x38: "CP_SET_BIN",
    0x3d: "CP_MEM_WRITE",
    0x3f: "CP_INDIRECT_BUFFER_PFE",
    0x40: "CP_CONTINUE",
    0x41: "CP_SET_PROTECTED_MODE",
    0x42: "CP_SET_SECURE_MODE",
    0x46: "CP_EVENT_WRITE",
    0x47: "CP_EVENT_WRITE_64",
    0x48: "CP_EVENT_WRITE_ZERO",
    0x49: "CP_RUN_APPLICATION",
    0x4b: "CP_DRAW_INDX_OFFSET",
    0x5c: "CP_SET_MARKER",
    0x63: "CP_BLIT",
    0x84: "CP_SET_SUBDRAW_SIZE",
}

EVENTS = {
    0x04: "CACHE_FLUSH_TS",
    0x31: "CACHE_CLEAN",
    0x07: "CACHE_INVALIDATE",
}

line_re = re.compile(r"MONDRIAN GPU: rtail ([0-9a-f]+)((?: [0-9a-f]{8})+)")


def dwords(text):
    out = []
    for match in line_re.finditer(text):
        out.extend(int(w, 16) for w in match.group(2).split())
    return out


def decode(words):
    i = 0
    while i < len(words):
        w = words[i]
        kind = (w >> 28) & 0xf
        if kind == 0x7:
            opcode = (w >> 16) & 0x7f
            count = w & 0x3fff
            name = TYPE7_NAMES.get(opcode, "type7")
            payload = words[i + 1:i + 1 + count]
            extra = ""
            if opcode == 0x46 and payload:
                event = payload[0] & 0x3f
                dest = (payload[1] | (payload[2] << 32)) if len(payload) > 2 else 0
                value = payload[3] if len(payload) > 3 else 0
                extra = (" %s dest 0x%x value 0x%x" %
                         (EVENTS.get(event, "event 0x%x" % event), dest, value))
            elif opcode == 0x3d and len(payload) > 2:
                dest = payload[0] | (payload[1] << 32)
                extra = " dest 0x%x value 0x%x" % (dest, payload[2])
            elif opcode == 0x3f and len(payload) > 2:
                ib = payload[0] | (payload[1] << 32)
                extra = " ib 0x%x size 0x%x" % (ib, payload[2])
            print("%04x  type7 %-26s op 0x%02x count %-3u%s" %
                  (i, name, opcode, count, extra))
            i += 1 + count
        elif kind == 0x4:
            reg = (w >> 8) & 0x3ffff
            count = w & 0x7f
            payload = words[i + 1:i + 1 + count]
            print("%04x  type4 reg 0x%05x count %-3u %s" %
                  (i, reg, count, " ".join("%08x" % p for p in payload)))
            i += 1 + count
        else:
            print("%04x  type%d 0x%08x" % (i, kind, w))
            i += 1


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    with open(sys.argv[1], "rb") as f:
        text = f.read().replace(b"\0", b"\n").decode("utf-8", "replace")
    words = dwords(text)
    if not words:
        print("no rtail lines in that file (is the driver built with 0323?)")
        return 1
    decode(words)
    return 0


if __name__ == "__main__":
    sys.exit(main())
