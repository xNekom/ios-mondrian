#!/usr/bin/env python3
"""Drive the QCA6490 firmware download from the host.

`btuart cmd <hex>` puts whatever HCI packet it is given on the wire and prints
the event, without touching the root clock (a second RCG change in one boot
wedges the channel). That is enough to speak btqca's protocol from here, where
it is easy to change:

  * `HCI_Reset` and `Read Local Version` come from `btuart hci115`, which also
    programs the engine for 115200 the first time in the boot.
  * `EDL_PATCH_VER_REQ_CMD` (0xFC00 with 0x19) names the ROM.
  * `EDL_PATCH_CONFIG_CMD` (0xFC00 with 0x28 0x01 0 0 0) is what the WCN6855
    class needs before a patch, per btqca's qca_send_patch_config_cmd.
  * the TLV file is streamed **raw** in 243-byte pieces, each as 0xFC00 with
    [0x1E, length, data...]; the controller parses the TLV itself
    (qca_tlv_dnld_cmd does exactly this).
  * the NVM file goes the same way.

Usage:
  tools/bt-download.py --fw .../hpbtfw21.tlv --nvm .../hpnv21.bin
  tools/bt-download.py --steps on,hci115,edl        # stop before the blobs
"""

import argparse
import socket
import sys
import time

PHONE = ("192.168.7.2", 5141)
SEG = 243


def simple(cmd, timeout=6.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(cmd.encode(), PHONE)
        data, _ = s.recvfrom(4096)
        return data.decode(errors="replace").strip()
    except socket.timeout:
        return None
    finally:
        s.close()


def hci_packet(opcode, params):
    return bytes([0x01, opcode & 0xff, (opcode >> 8) & 0xff,
                  len(params)]) + params


def send_cmd(opcode, params, timeout=6.0):
    return simple("btuart cmd " + hci_packet(opcode, params).hex(), timeout)


def stream(name, blob, timeout=4.0):
    total = len(blob)
    sent = 0
    t0 = time.time()
    while sent < total:
        piece = blob[sent:sent + SEG]
        answer = send_cmd(0xFC00, bytes([0x1E, len(piece)]) + piece, timeout)
        sent += len(piece)
        if sent % (SEG * 40) < SEG or sent == total:
            print("  %s %u/%u bytes (%.0fs)%s"
                  % (name, sent, total, time.time() - t0,
                     "" if answer else "  no event"), flush=True)
        if answer is None and sent == total:
            print("  last segment had no answer", flush=True)
    return sent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fw")
    ap.add_argument("--nvm")
    ap.add_argument("--steps", default="on,hci115,edl,config,fw,nvm")
    args = ap.parse_args()
    steps = [s.strip() for s in args.steps.split(",") if s.strip()]

    if "on" in steps:
        print("== btuart on", flush=True)
        print(simple("btuart on", 20) or "no answer", flush=True)

    if "hci115" in steps:
        print("== btuart hci115 (reset + version, first clock change)", flush=True)
        print(simple("btuart hci115", 30) or "no answer", flush=True)

    if "edl" in steps:
        print("== EDL_PATCH_VER_REQ_CMD", flush=True)
        print(send_cmd(0xFC00, b"\x19") or "no answer", flush=True)
        print("== EDL_GET_BUILD_INFO_CMD", flush=True)
        print(send_cmd(0xFC00, b"\x20") or "no answer", flush=True)
        print("== EDL_GET_BID_REQ_CMD", flush=True)
        print(send_cmd(0xFC00, b"\x23") or "no answer", flush=True)

    if "config" in steps:
        print("== EDL_PATCH_CONFIG_CMD", flush=True)
        print(send_cmd(0xFC00, b"\x28\x01\x00\x00\x00") or "no answer",
              flush=True)

    if "fw" in steps:
        if not args.fw:
            raise SystemExit("--fw is needed for the fw step")
        with open(args.fw, "rb") as f:
            blob = f.read()
        print("== patch: %s, %u bytes, %u segments"
              % (args.fw, len(blob), (len(blob) + SEG - 1) // SEG), flush=True)
        stream("patch", blob)

    if "nvm" in steps:
        if not args.nvm:
            raise SystemExit("--nvm is needed for the nvm step")
        with open(args.nvm, "rb") as f:
            blob = f.read()
        print("== nvm: %s, %u bytes" % (args.nvm, len(blob)), flush=True)
        stream("nvm", blob)

    print("== pos: %s" % (simple("pos", 5) or "no answer"), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
