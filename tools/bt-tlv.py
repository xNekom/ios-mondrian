#!/usr/bin/env python3
"""Read a Qualcomm Bluetooth TLV (patch) or NVM blob, the way btqca does.

The file starts with a `tlv_type_hdr`: a little-endian u32 whose **low byte is
the type** and whose **bits 8..31 are the payload length**, which is not the
u16/u16 split it looks like. Behind it:

- a patch (`TLV_TYPE_PATCH`, types 1) carries a packed `tlv_type_patch`
  (total size, data length, format, signature, download mode, product/rom/patch
  versions and entry point) and then its segments.
- an NVM carries a table of packed `tlv_type_nvm` entries: tag id, tag length,
  two reserved words and the data. The vendor ships one file per board ID
  because only the entry matching the BID applies.

The loader does **not** chop the file into segments itself: it streams the raw
bytes in 243-byte pieces, each as HCI 0xFC00 with [0x1E, length, data...], and
the controller parses the TLV. This tool is for reading and sanity-checking the
blobs.

    tools/bt-tlv.py FIRMWARE.tlv [FIRMWARE.nvm]

No device data is involved: these files come from the ROM.
"""

import struct
import sys

PATCH_HDR = struct.Struct("<IIBBBBHHHHI")     # 24 bytes, packed
NVM_HDR = struct.Struct("<HHII")              # 12 bytes, packed


def hdr(data, at=0):
    v = struct.unpack_from("<I", data, at)[0]
    return v & 0xff, (v >> 8) & 0xffffff


def show_patch(data):
    ttype, tlen = hdr(data)
    print("header: type 0x%x, payload %d bytes (file %d)"
          % (ttype, tlen, len(data)))
    if ttype != 1:
        print("  (type 1 is TLV_TYPE_PATCH)")
    (total, dlen, fmt, sig, mode, _r, pid, rom, patch_ver, _r2,
     entry) = PATCH_HDR.unpack_from(data, 4)
    print("  total %u, data %u, format %u, signature 0x%x, download mode %u"
          % (total, dlen, fmt, sig, mode))
    print("  product 0x%04x, rom 0x%04x, patch 0x%04x, entry 0x%x"
          % (pid, rom, patch_ver, entry))
    at = 4 + PATCH_HDR.size
    payload = len(data) - at
    print("  %u bytes of patch payload after the header" % payload)
    print("  (the loader streams these bytes as they are: btqca does not split "
          "the file, it sends 243-byte pieces and the controller parses the TLV)")
    if payload != total - 8:
        print("  note: payload does not match total_size - 8 (%d)" % (total - 8))


def show_nvm(data):
    ttype, tlen = hdr(data)
    print("NVM: %d bytes, header type 0x%x, payload %d"
          % (len(data), ttype, tlen))
    at = 4
    end = min(len(data), 4 + tlen)
    n = 0
    while at + NVM_HDR.size <= end:
        tag, tlen2, _r1, _r2 = NVM_HDR.unpack_from(data, at)
        at += NVM_HDR.size
        if tlen2 > end - at:
            print("  entry %d: tag 0x%04x claims %u bytes, %u left; stop"
                  % (n, tag, tlen2, end - at))
            break
        print("  entry %d: tag 0x%04x, %u bytes%s"
              % (n, tag, tlen2,
                 "  (BD address)" if tag == 2 else
                 "  (HCI config)" if tag == 17 else
                 "  (deep sleep)" if tag == 27 else ""))
        at += tlen2
        n += 1
        if n > 18:
            print("  ... (%d bytes left)" % (end - at))
            break


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    with open(sys.argv[1], "rb") as f:
        show_patch(f.read())
    if len(sys.argv) > 2:
        with open(sys.argv[2], "rb") as f:
            show_nvm(f.read())
    return 0


if __name__ == "__main__":
    sys.exit(main())
