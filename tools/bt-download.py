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
  * the NVM is streamed the same way, but **not** untouched: its HCI tag carries
    the UART rate the controller switches to when it applies the file, and the
    stock `hpnv21.bin` says `0x11` (`QCA_BAUDRATE_3200000`). Sending it as-is
    moved the chip to 3.2 Mbaud and every later command went unanswered. btqca
    rewrites that byte before sending, and so does `patch_nvm()`.
  * after the NVM, btqca disables SoC logging (0xFC17 with [0x14, 0x00]), runs
    HCI_Reset and reads the build info; `--steps post` does the same.

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

# struct tlv_type_nvm { u16 tag_id; u16 tag_len; u32 r1; u32 r2; u8 data[]; }
EDL_TAG_ID_HCI = 0x11
EDL_TAG_ID_DEEP_SLEEP = 0x1B

# btqca's enum qca_btsoc_baudrate, the byte the HCI tag carries.
BAUD_CODES = {115200: 0, 57600: 1, 38400: 2, 19200: 3, 9600: 4, 230400: 5,
              250000: 6, 460800: 7, 500000: 8, 720000: 9, 921600: 10,
              1000000: 11, 1250000: 12, 2000000: 13, 3000000: 14, 4000000: 15,
              1600000: 16, 3200000: 17, 3500000: 18}


def patch_nvm(blob, baud):
    """Rewrite the NVM tags the way `qca_tlv_check_data` does before sending.

    The HCI tag carries the UART rate the controller switches to once the NVM is
    applied, and the stock file says `0x11` = `QCA_BAUDRATE_3200000`. Sending it
    unmodified moved our chip to 3.2 Mbaud and it answered nothing afterwards
    (measured: silence at 115200 from the byte after the last segment). btqca
    sets the in-band sleep bit and overwrites the rate with the one the driver
    will actually use, so this does the same.
    """
    b = bytearray(blob)
    type_len = int.from_bytes(b[0:4], "little")
    end = min(4 + (type_len >> 8), len(b))
    idx = 4
    notes = []
    while idx + 12 <= end:
        tag = int.from_bytes(b[idx:idx + 2], "little")
        tlen = int.from_bytes(b[idx + 2:idx + 4], "little")
        data = idx + 12
        if data + tlen > end:
            break
        if tag == EDL_TAG_ID_HCI and tlen >= 3:
            was = (b[data], b[data + 1])
            b[data] |= 0x80
            b[data + 1] = baud
            notes.append("HCI tag %02x %02x -> %02x %02x"
                         % (was[0], was[1], b[data], b[data + 1]))
        elif tag == EDL_TAG_ID_DEEP_SLEEP and tlen >= 1:
            b[data] |= 0x01
        idx = data + tlen
    return bytes(b), notes


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
    """Burst the file out; the controller only acks the last segment.

    A segment whose answer says the TX FIFO never drained means the engine
    stopped draining: the burst cannot make progress, so stop instead of pushing
    600 more commands at a stalled controller.
    """
    total = len(blob)
    sent = 0
    t0 = time.time()
    while sent < total:
        piece = blob[sent:sent + SEG]
        last = sent + len(piece) >= total
        params = bytes([0x1E, len(piece)]) + piece
        if last:
            answer = send_cmd(0xFC00, params, 10.0)
        else:
            answer = send_quiet(0xFC00, params, 8.0)
        sent += len(piece)
        if answer and "never drained" in answer:
            print("  %s stalled at %u/%u bytes: the engine stopped draining"
                  % (name, sent, total), flush=True)
            print(answer, flush=True)
            return sent
        if sent % (SEG * 100) < SEG or last:
            print("  %s %u/%u bytes (%.0fs)"
                  % (name, sent, total, time.time() - t0), flush=True)
    return sent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fw")
    ap.add_argument("--nvm")
    ap.add_argument("--steps", default="on,hci115,edl,fw,nvm,post")
    ap.add_argument("--nvm-baud", type=int, default=115200,
                    help="UART rate written into the NVM's HCI tag")
    ap.add_argument("--nvm-raw", action="store_true",
                    help="send the NVM file untouched")
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
        if args.nvm_raw:
            print("== nvm: %s, %u bytes (raw)" % (args.nvm, len(blob)),
                  flush=True)
        else:
            blob, notes = patch_nvm(blob, BAUD_CODES[args.nvm_baud])
            print("== nvm: %s, %u bytes at %u baud"
                  % (args.nvm, len(blob), args.nvm_baud), flush=True)
            for note in notes:
                print("   " + note, flush=True)
        stream("nvm", blob)

    if "post" in steps:
        print("== QCA_DISABLE_LOGGING (0xFC17 [0x14, 0x00])", flush=True)
        print(send_cmd(0xFC17, b"\x14\x00") or "no answer", flush=True)
        print("== HCI_Reset", flush=True)
        print(send_cmd(0x0C03, b"") or "no answer", flush=True)
        print("== Read Local Version (a patched controller stops reporting 0x38e6)",
              flush=True)
        print(send_cmd(0x1001, b"") or "no answer", flush=True)

    print("== pos: %s" % (simple("pos", 5) or "no answer"), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
