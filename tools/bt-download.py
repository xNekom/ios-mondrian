#!/usr/bin/env python3
"""Drive the QCA6490 firmware download from the host.

`btuart cmd <hex>` puts whatever HCI packet it is given on the wire and prints
the event, without touching the root clock (a second RCG change in one boot
wedges the channel). That is enough to speak btqca's protocol from here, where
it is easy to change:

  * `HCI_Reset` and `Read Local Version` come from `btuart hci115`, which also
    programs the engine for 115200 the first time in the boot.
  * `EDL_PATCH_VER_REQ_CMD` (0xFC00 with 0x19) names the ROM: product, ROM
    version, patch version and soc id. The ROM version picks the file, and the
    patch version changing (`0x38e6` -> `0x5e81`) is what proves the download.
  * `EDL_GET_BUILD_INFO_CMD` (0x20) and `EDL_GET_BID_REQ_CMD` (0x23) name the
    build string and the board id that picks the NVM.
  * `EDL_PATCH_CONFIG_CMD` (0xFC00 with 0x28 0x01 0 0 0) is btqca's
    `qca_send_patch_config_cmd`, which it sends on the **WCN6750** path only, and
    which this chip answers with `cresp 0x10`. It is not in the default steps.
  * the TLV file is streamed **raw** in 243-byte pieces, each as 0xFC00 with
    [0x1E, length, data...]; the controller parses the TLV itself.

The pacing is the part that cost a boot. `qca_tlv_check_data` reads
`download_mode` out of the patch TLV and the WCN6855 files say 3, which is
`QCA_SKIP_EVT_VSE_CC`: btqca sends every segment with `__hci_cmd_send`, no event
waited for, and only the last one is acked (`qca_download_firmware` forces
`QCA_SKIP_EVT_NONE` when `!remain`). Waiting per segment here turned a 20-second
download into 234 seconds of empty 300 ms reads and then a stalled engine, so
the burst goes out with `btuart cmd0` (send, do not read) and the result is
checked with a fresh version request instead of an event.

Usage:
  tools/bt-download.py --fw .../hpbtfw21.tlv --nvm .../hpnv21.bin
  tools/bt-download.py --steps on,hci115,edl        # stop before the blobs
"""

import argparse
import re
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


def send_quiet(opcode, params, timeout=6.0):
    return simple("btuart cmd0 " + hci_packet(opcode, params).hex(), timeout)


def events(text):
    """Every `rx data:` line in a btuart answer, as byte strings."""
    out = []
    for line in (text or "").splitlines():
        m = re.search(r"rx data:([0-9a-f ]+)", line)
        if m:
            out.append(bytes.fromhex(m.group(1).replace(" ", "")))
    return out


def versions(text):
    """Decode an EDL_PATCH_VER_REQ answer into `qca_btsoc_version`.

    The return parameters are `[cresp 0x00][rtype 0x19][len 0x0c]` and then the
    twelve bytes of `struct qca_btsoc_version` -- product id, patch version, ROM
    version and soc id. That ROM version is what picks the file: `0x0201` is the
    `hpbtfw21`/`hpnv21` pair. Before a patch the patch version is the ROM's own
    subversion (`0x38e6`); a loaded patch replaces it (`0x5e81` in
    `hpbtfw21.tlv`), which is how the download is verified.
    """
    for ev in events(text):
        if len(ev) < 15 or ev[0] != 0x04 or ev[1] != 0x0e:
            continue
        body = ev[6:]
        if len(body) < 15 or body[1] != 0x19:
            continue
        p = body[3:15]
        return (int.from_bytes(p[0:4], "little"), int.from_bytes(p[4:6], "little"),
                int.from_bytes(p[6:8], "little"), int.from_bytes(p[8:12], "little"))
    return None


def show_versions(got):
    if not got:
        return
    print("   product 0x%08x patch 0x%04x rom 0x%04x soc 0x%08x"
          % got, flush=True)
    print("   file: hpbtfw%02x.tlv / hpnv%02x.*" % (got[2] & 0xff, got[2] & 0xff),
          flush=True)


def ask_versions(tries=3):
    for _ in range(tries):
        got = versions(send_cmd(0xFC00, b"\x19", 8.0))
        if got:
            return got
        time.sleep(1.0)
    return None


def stream(name, blob):
    """Burst the file out; the controller only acks the last segment."""
    total = len(blob)
    sent = 0
    t0 = time.time()
    while sent < total:
        piece = blob[sent:sent + SEG]
        last = sent + len(piece) >= total
        params = bytes([0x1E, len(piece)]) + piece
        if last:
            send_cmd(0xFC00, params, 10.0)
        else:
            send_quiet(0xFC00, params, 8.0)
        sent += len(piece)
        if sent % (SEG * 100) < SEG or last:
            print("  %s %u/%u bytes (%.0fs)"
                  % (name, sent, total, time.time() - t0), flush=True)
    return sent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fw")
    ap.add_argument("--nvm")
    ap.add_argument("--steps", default="on,hci115,edl,fw,nvm")
    args = ap.parse_args()
    steps = [s.strip() for s in args.steps.split(",") if s.strip()]

    if "on" in steps:
        print("== btuart on", flush=True)
        print(simple("btuart on", 20) or "no answer", flush=True)

    if "hci115" in steps:
        print("== btuart hci115 (reset + version, first clock change)", flush=True)
        print(simple("btuart hci115", 30) or "no answer", flush=True)

    if "edl" in steps:
        print("== EDL_PATCH_VER_REQ_CMD (the ROM)", flush=True)
        answer = send_cmd(0xFC00, b"\x19", 8.0)
        print(answer or "no answer", flush=True)
        show_versions(versions(answer))
        print("== EDL_GET_BUILD_INFO_CMD", flush=True)
        print(send_cmd(0xFC00, b"\x20") or "no answer", flush=True)
        print("== EDL_GET_BID_REQ_CMD", flush=True)
        print(send_cmd(0xFC00, b"\x23") or "no answer", flush=True)

    if "config" in steps:
        print("== EDL_PATCH_CONFIG_CMD (WCN6750-class path)", flush=True)
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
        got = ask_versions()
        if got:
            print("   after the patch:", flush=True)
            show_versions(got)
        else:
            print("   no version after the patch", flush=True)

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
