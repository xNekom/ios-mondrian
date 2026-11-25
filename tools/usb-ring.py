#!/usr/bin/env python3
"""Host side of the phone's USB control channel (udp/5141).

The kernel's USB gadget (bsd/dev/mondrian_usb.c, boot-arg usb=2) answers on
192.168.7.2 after tools/ios-usbnet.sh has given the host interface
192.168.7.1/24.  Commands:

  dump [FILE]   the whole 4 MiB console ring, reassembled a chunk at a time
  prev [FILE]   the PREVIOUS boot's console, from the partition (kernel 0329):
                the panic report that a reset would otherwise carry away
  pos           the ring's absolute position
  mem           print the compressor and GPU-buffer histogram to the live log
  tap X Y       one synthetic touch, panel pixels (1440x3200)
  swipe X1 Y1 X2 Y2 [MS]
                a straight synthetic swipe, sampled every 8 ms
  key N down|up 0 power, 1 volume up, 2 volume down, 3 home,
                4 brightness up, 5 brightness down
  screen [FILE] half-scale capture of the panel, as a PNG
  fps [SECONDS] how often the panel's memory changes: the frames the glass shows
  sa SID CHAN DIV
                one PMK8350 VADC channel in mV (sid 3 = PM8350B; the
                divider is the channel's qcom,pre-scaling, e.g. 3 for
                vbat_sns <1 3> and 16 for usb_in_v_div_16 <1 16>)
  reboot        flush the ring, point the BCB at the bootloader and reset
  respring      restart SpringBoard, by the PID the kernel's own SMP line names
  poweroff      flush the ring, let the gadget go and switch the SoC off

Why this exists: the live log on udp/5140 only carries what is written after
it starts, a frozen UI used to force a power cycle plus a recovery dump to
read the ring, and a swipe had to be reproduced by hand at the right moment.
With this, the whole loop is the USB cable.
"""
import argparse
import errno
import os
import socket
import struct
import sys
import tempfile
import time
import zlib

PHONE = ("192.168.7.2", 5141)
HOST = ("192.168.7.1", 5141)
MAGIC = b"RLG1"
END = 0xFFFFFFFF


def open_socket(timeout=2.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(HOST)
    s.settimeout(timeout)
    return s


def simple(command, timeout=2.0):
    s = open_socket(timeout)
    s.sendto(command.encode(), PHONE)
    try:
        data, _ = s.recvfrom(2048)
        return data
    except socket.timeout:
        return None
    finally:
        s.close()


CHUNK = 1200
# Datagrams in flight before asking how far the kernel got. Sending a whole
# file unpaced loses nearly all of it: measured 2026-11-19, an 11.5 MB dylib
# arrived 0 of 11539920 bytes on all three attempts, while a 66 KB program went
# through, because the kernel counts only the contiguous prefix and the phone
# drops what arrives ahead of a hole.
WINDOW = 24


def wfile_attempt(path, data):
    """One delivery attempt. Returns (bytes the kernel took, write errno)."""
    answer = simple(f"wfile {path} {len(data)}", 5.0)
    if answer is None:
        print("no answer to wfile", file=sys.stderr)
        return 0, 0
    print(answer.decode(errors="replace").strip(), file=sys.stderr)

    s = open_socket(1.0)
    got = 0
    err = 0
    try:
        stalls = 0
        while got < len(data):
            # Send from the contiguous prefix only, a window at a time: the
            # kernel accepts an offset at or before what it already has, and
            # refuses anything ahead of it.
            offset = got
            end = min(len(data), got + WINDOW * (CHUNK - 8))
            while offset < end:
                body = data[offset:offset + CHUNK - 8]
                s.sendto(b"RLW1" + struct.pack("<I", offset) + body, PHONE)
                offset += len(body)
            # The write happens when the last byte lands; wstat says whether
            # the kernel got there, and how much of the prefix it holds.
            moved = False
            for _ in range(50):
                reply = simple("wstat", 1.0)
                if reply is not None:
                    parts = reply.decode(errors="replace").split()
                    if len(parts) >= 2 and parts[0] == "wstat":
                        now = int(parts[1])
                        if now > got:
                            got = now
                            moved = True
                            break
                time.sleep(0.03)
            stalls = 0 if moved else stalls + 1
            if stalls >= 40:            # ten seconds with no byte: give up
                break
        if got >= len(data):
            # The kernel answers the last byte with the write's own result,
            # "wfile PATH LEN bytes -> errno". Without this read a write that
            # failed (ENOSPC, EROFS) looked exactly like a delivered one: the
            # file is created, truncated and left empty, and the next boot
            # loads nothing (measured 2026-11-20).
            s.settimeout(3.0)
            try:
                reply = s.recv(512)
            except OSError:
                reply = b""
            text = reply.decode(errors="replace").strip()
            if text:
                print(text, file=sys.stderr)
            tail = text.rsplit("->", 1)
            if len(tail) == 2:
                try:
                    err = int(tail[1])
                except ValueError:
                    err = 0
    finally:
        s.close()
    return got, err


def wfile(path, local):
    """Replace one file in the mounted root, over the control channel.

    The kernel opens the path with O_TRUNC and writes what it received, so a
    dylib can be swapped without a userdata flash (bsd/dev/mondrian_usb.c,
    "wfile"). A file a process has mapped must be killed first: the caller's
    job, and the usual reason for `kill`.

    A delivery that stops halfway leaves a truncated dylib behind, and the next
    process to load it fails in ways that have nothing to do with its code
    (measured 2026-11-18: a 3 576-byte hook whose first functions still ran, so
    the tick printed once and then nothing). Retry inside the tool, and only
    then report; the caller does not have to parse the count.
    """
    data = open(local, "rb").read()
    got = 0
    # A 22 MB dylib stalls more often than a 3 KB one, and a truncated dylib is
    # refused by dyld with no message anywhere: the process simply keeps the
    # Metal it would have had. Give the big ones more attempts. A write error is
    # not retried: the delivery worked, the filesystem refused the file.
    attempts = 9 if len(data) > (4 << 20) else 3
    for attempt in range(1, attempts + 1):
        got, err = wfile_attempt(path, data)
        if got >= len(data) and err == 0:
            print(f"wfile {path}: {got} of {len(data)} bytes delivered")
            time.sleep(0.5)
            return 0
        if got >= len(data):
            hint = " (the root is full)" if err == errno.ENOSPC else ""
            print(f"wfile {path}: the kernel refused the write, errno {err}"
                  f"{hint}; the file on the phone is empty or truncated",
                  file=sys.stderr)
            return 1
        print(f"wfile {path}: {got} of {len(data)} on attempt {attempt}, retrying",
              file=sys.stderr)
        time.sleep(1.0)
    print(f"wfile {path}: INCOMPLETE after {attempts} attempts, {got} of "
          f"{len(data)} bytes; the file on the phone is truncated", file=sys.stderr)
    return 1


def request_chunk(s, offset):
    s.sendto(b"RLQ1" + struct.pack("<I", offset), PHONE)


def dump(path, timeout, start=None, total=None):
    if total is None:
        answer = simple("pos")
        if answer is None:
            print("no answer to pos", file=sys.stderr)
            return 1
        total = int(answer.decode().strip())
    if start is None:
        start = max(0, total - (4 << 20))

    # One datagram per request, a few in flight: the gadget's TX queue holds
    # 32 frames, and a burst of the whole ring loses most of it.
    s = open_socket(1.0)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    except OSError:
        pass

    chunks = {}
    next_offset = start
    pending = {}
    deadline = time.time() + timeout
    last_progress = time.time()
    window = 24

    while time.time() < deadline:
        while len(pending) < window and next_offset < total:
            request_chunk(s, next_offset)
            pending[next_offset] = time.time()
            next_offset += CHUNK
        if not pending:
            break
        try:
            data, _ = s.recvfrom(2048)
        except socket.timeout:
            now = time.time()
            for offset, sent in list(pending.items()):
                if now - sent > 0.5:
                    request_chunk(s, offset)
                    pending[offset] = now
            if now - last_progress > 6:
                break
            continue
        if len(data) < 8 or data[:4] != MAGIC:
            continue
        offset = struct.unpack("<I", data[4:8])[0]
        if offset in pending:
            del pending[offset]
        chunks[offset] = data[8:]
        last_progress = time.time()
    s.close()

    if not chunks:
        print("no data: is the phone on usb=2 and 192.168.7.1/24 set?", file=sys.stderr)
        return 1

    ring = bytearray(total - start)
    holes = 0
    at = start
    for offset in sorted(chunks):
        if offset > at:
            holes += offset - at
        body = chunks[offset]
        lo = offset - start
        ring[lo:lo + len(body)] = body
        at = max(at, offset + len(body))
    if at < total:
        holes += total - at
    with open(path, "wb") as f:
        f.write(ring)
    print(f"{len(ring)} bytes, {len(chunks)} datagrams, {holes} bytes missing -> {path}")
    return 0


def springboard_pid(text):
    """The SpringBoard PID from the kernel's own `SMP t=...` line, or None.

    Only that line: a log line that happens to mention `SpringBoard(27)` sent a
    `kill 27` to some other process instead (measured 2026-11-18).
    """
    pid = None
    for line in text.splitlines():
        if "SMP t=" not in line or "SpringBoard(" not in line:
            continue
        at = line.rfind("SpringBoard(")
        end = line.find(")", at)
        if end > at:
            pid = line[at + len("SpringBoard("):end]
    return pid


def backboardd_pid(text):
    """The backboardd PID from the kernel's `SMP t=...` line, or None.

    Killing SpringBoard alone leaves the new one on its boot spinner with no
    commit; the render server is the one that has to restart (measured
    2026-11-21). Only the SMP line is trusted, for the same reason.
    """
    pid = None
    for line in text.splitlines():
        if "SMP t=" not in line or "backboardd(" not in line:
            continue
        at = line.rfind("backboardd(")
        end = line.find(")", at)
        if end > at:
            pid = line[at + len("backboardd("):end]
    return pid


def respring():
    """Restart the render server and SpringBoard.

    Not a reliable reload path: measured 2026-11-23, every signal order
    (SpringBoard alone, backboardd alone, both, and backboardd first) left a
    black panel and `loop 0 in 1 s`. Reboot and boot the image again instead.
    A rebuilt hook is only mapped by a new SpringBoard.

    `kill` takes a PID. `kill SpringBoard` is `kill 0` -- measured 2026-11-18: it
    answers `kill 0 -> 3` and nothing restarts, so a rebuilt hook is never mapped
    and every new probe reads exactly like "the new code did not run". The PID
    comes from the kernel, which prints `SpringBoard(pid)` every few seconds.
    """
    fd, path = tempfile.mkstemp(suffix=".ring")
    os.close(fd)
    try:
        if dump(path, 60.0) != 0:
            return 1
        with open(path, "r", errors="replace") as f:
            text = f.read()
    finally:
        os.remove(path)
    spid = springboard_pid(text)
    bpid = backboardd_pid(text)
    if spid is None and bpid is None:
        print("no SpringBoard or backboardd pid in the ring", file=sys.stderr)
        return 1
    # Only the render server is signalled, because a SpringBoard-only kill
    # leaves the new one at its boot spinner: both processes alive and drawing
    # frames, the panel shows the spinner. Measured 2026-11-21 backboardd alone
    # once presented a new SpringBoard (27/s); measured 2026-11-23 it did not --
    # SpringBoard alone, backboardd alone, both together and the reverse pair
    # all ended black with `loop 0 in 1 s`, and only a reboot recovered. Check
    # the panel after the call; the SpringBoard pid is the fallback for a kernel
    # that does not print backboardd.
    if bpid is not None:
        print(f"backboardd pid {bpid}")
        answer = simple("kill " + bpid, 5.0)
        print(answer.decode(errors="replace").strip() if answer else "no answer")
    elif spid is not None:
        print(f"SpringBoard pid {spid}")
        answer = simple("kill " + spid, 5.0)
        print(answer.decode(errors="replace").strip() if answer else "no answer")
    return 0


def prev(path, timeout):
    """The previous boot's console, from the partition, over the live channel.

    The kernel copies the previous boot's ring out of userdata before this
    boot's first flush (bsd/dev/mondrian_ufs.c, 0329) and prints it into the
    current ring on request, so the reply is the ring position the lines start
    at and the usual chunk loop fetches them.
    """
    answer = simple("prev", 5.0)
    if answer is None:
        print("no answer to prev: this kernel has no 0329", file=sys.stderr)
        return 1
    text = answer.decode(errors="replace").strip()
    if not text.isdigit():
        print(f"prev answered {text!r}", file=sys.stderr)
        return 1
    start = int(text)
    after = simple("pos")
    if after is None:
        print("no answer to pos", file=sys.stderr)
        return 1
    total = int(after.decode().strip())
    if total <= start:
        print("prev printed nothing into the ring", file=sys.stderr)
        return 1
    return dump(path, timeout, start=start, total=total)


def fps(seconds):
    """Frames the glass actually shows: how often the panel's memory changes.

    Sampled through the screen dump's row requests, so it needs no new kernel
    code: a handful of rows spread over the panel, hashed, and counted when
    the hash changes. Every counter on the phone answers a different
    question -- `fps` counts swaps, `present` counts the driver's own
    presents, and the compositor's rate only counts frames that end in the GL
    shim's flush -- so this is the only one that reads the glass.
    """
    rows = (160, 400, 800, 1200, 1600, 2000, 2400, 2800)
    s = open_socket(1.0)
    start = time.monotonic()
    end = start + seconds
    last = None
    changes = 0
    samples = 0
    worst = 0.0
    last_change = None
    try:
        while time.monotonic() < end:
            got = {}
            for attempt in range(3):
                missing = [row for row in rows if row not in got]
                if not missing:
                    break
                for row in missing:
                    s.sendto(b"RLS1" + struct.pack("<H", row), PHONE)
                deadline = time.monotonic() + 0.05
                while len(got) < len(rows) and time.monotonic() < deadline:
                    try:
                        data, _ = s.recvfrom(2048)
                    except socket.timeout:
                        break
                    if len(data) < 6 or data[:4] != ROW_MAGIC:
                        continue
                    got[struct.unpack("<H", data[4:6])[0]] = data[6:]
            if len(got) < len(rows):
                # (a lost row is retried above; a gadget that answers none is
                # a real fault and would never leave this loop)
                print("no screen rows (is the gadget up?)", file=sys.stderr)
                return 1
            sig = hash(tuple(got[row] for row in rows))
            now = time.monotonic()
            samples += 1
            if last is not None and sig != last:
                changes += 1
                if last_change is not None:
                    worst = max(worst, now - last_change)
                last_change = now
            last = sig
    finally:
        s.close()
    span = time.monotonic() - start
    print(f"{changes} panel changes in {span:.2f} s, "
          f"{changes / span:.1f} a second, {samples / span:.0f} samples a second, "
          f"longest still {worst * 1000:.0f} ms")
    return 0


def touch(x1, y1, x2, y2, ms=0):
    """Panel pixels (1440x3200); ms=0 is a tap, otherwise a swipe."""
    s = open_socket(2.0)
    request = b"RLT1" + struct.pack("<5H", x1, y1, x2, y2, ms)
    s.sendto(request, PHONE)
    s.close()


def key(code, down):
    """0 power, 1 vol up, 2 vol down, 3 home, 4/5 brightness up/down."""
    s = open_socket(2.0)
    s.sendto(b"RLK1" + bytes((code, 1 if down else 0)), PHONE)
    s.close()


ROW_MAGIC = b"RLP1"


def screen(path, rows, timeout):
    """Half-scale RGB565 of the panel, as a PNG.

    One row per request: the reply is 1446 bytes, under the interface MTU, and
    the gadget's transmit queue holds only 32 frames, so a stream needs the
    same windowed request/response the ring dump uses.
    """
    s = open_socket(1.0)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    except OSError:
        pass

    got = {}
    next_row = 0
    pending = {}
    deadline = time.time() + timeout
    last_progress = time.time()
    window = 24

    while time.time() < deadline and (next_row < rows or pending):
        while len(pending) < window and next_row < rows:
            s.sendto(b"RLS1" + struct.pack("<H", next_row), PHONE)
            pending[next_row] = time.time()
            next_row += 1
        try:
            data, _ = s.recvfrom(2048)
        except socket.timeout:
            now = time.time()
            for row, sent in list(pending.items()):
                if now - sent > 0.5:
                    s.sendto(b"RLS1" + struct.pack("<H", row), PHONE)
                    pending[row] = now
            if now - last_progress > 6:
                break
            continue
        if len(data) < 6 or data[:4] != ROW_MAGIC:
            continue
        row = struct.unpack("<H", data[4:6])[0]
        pending.pop(row, None)
        got[row] = data[6:]
        last_progress = time.time()
    s.close()

    if not got:
        print("no screen data (older kernel?)", file=sys.stderr)
        return 1
    width = max(len(body) for body in got.values()) // 2
    rows_got = max(got) + 1
    blank = b"\x00" * (width * 2)
    raw = bytearray()
    out_rows = 0
    # The kernel halves the columns and keeps every row, so the reply is 2:1
    # in pixels; keep every second row to write a PNG whose shape is the
    # panel's. Without this the image is stretched twice as tall as the glass
    # and a square icon measures 1:2.
    for row in range(0, rows_got, 2):
        out_rows += 1
        body = got.get(row, blank)
        if len(body) < width * 2:
            body = body + blank[:width * 2 - len(body)]
        rgb = bytearray(width * 3)
        for i in range(width):
            p = struct.unpack_from("<H", body, i * 2)[0]
            r = (p >> 11) & 0x1f
            g = (p >> 5) & 0x3f
            b = p & 0x1f
            rgb[i * 3] = (r << 3) | (r >> 2)
            rgb[i * 3 + 1] = (g << 2) | (g >> 4)
            rgb[i * 3 + 2] = (b << 3) | (b >> 2)
        raw += b"\x00" + rgb

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload +
                struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    import zlib
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, out_rows, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print(f"{width}x{out_rows} from {rows_got} panel rows {len(got)}/{rows_got} -> {path}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command",
                        choices=("dump", "prev", "wfile", "pos", "reboot", "respring", "poweroff", "mem", "tap", "swipe",
                                 "key", "screen", "bl", "dcs", "rd", "rr", "ww", "sr", "sw", "si", "sf", "smw", "sa", "sav", "keys", "bcb", "blob", "rtc",
                                 "execdeny", "gpukeep", "gpustat", "gpuperf", "temp", "tsens",
                                 "thermal", "burn", "haps", "vib", "hapb", "hapv", "hapr", "hapw", "spmimap",
                                 "btuart",
                                 "rf", "kill", "say", "fps", "del", "deltree", "ls", "wait"))
    parser.add_argument("args", nargs="*")
    parser.add_argument("--timeout", type=float, default=60.0,
                        help="seconds to wait for the dump (default 60)")
    parser.add_argument("--rows", type=int, default=3200,
                        help="panel rows to fetch (default 3200, the whole "
                             "panel; the PNG keeps every second row)")
    args = parser.parse_args()

    if args.command == "dump":
        path = args.args[0] if args.args else "usb-ring.txt"
        return dump(path, args.timeout)
    if args.command == "prev":
        path = args.args[0] if args.args else "usb-prev.txt"
        return prev(path, args.timeout)
    if args.command == "wfile":
        if len(args.args) < 2:
            print("usage: usb-ring.py wfile REMOTE-PATH LOCAL-FILE", file=sys.stderr)
            return 2
        return wfile(args.args[0], args.args[1])
    if args.command == "screen":
        path = args.args[0] if args.args else "usb-screen.png"
        return screen(path, args.rows, args.timeout)
    if args.command == "fps":
        return fps(float(args.args[0]) if args.args else 5.0)
    if args.command == "pos":
        # The ring's byte count, not a file's. A path argument used to be
        # ignored silently, so `pos LOG` read as the log's size and every pull
        # started past its end and came back empty (measured 2026-11-22).
        if args.args:
            print("pos reports the ring position, not a file size; a file's "
                  "length comes from reading it (tools/wsl/bt-read-log.sh)",
                  file=sys.stderr)
            return 2
        answer = simple("pos")
        if answer is None:
            print("no answer", file=sys.stderr)
            return 1
        print(answer.decode(errors="replace").strip())
        return 0
    if args.command == "rf":
        # Raw bytes on stdout: a daemon's stderr log is not text the ring can
        # format, and a short read must not be mistaken for an error line.
        if not args.args:
            print("usage: usb-ring.py rf PATH [OFFSET [LEN]]", file=sys.stderr)
            return 2
        path = args.args[0]
        off = args.args[1] if len(args.args) > 1 else "0"
        length = args.args[2] if len(args.args) > 2 else "1000"
        answer = simple("rf %s %s %s" % (path, off, length), 5.0)
        if answer is None:
            print("no answer", file=sys.stderr)
            return 1
        sys.stdout.buffer.write(answer)
        sys.stdout.buffer.flush()
        return 0
    if args.command == "mem":
        simple("mem")
        print("mem requested: the histogram goes to the live log (udp/5140)")
        return 0
    if args.command == "bl":
        # "bl" sets the backlight (level [fmt [cmd]]); with no level there is
        # nothing to set, and indexing args[0] threw an IndexError that read as
        # a broken tool rather than a missing argument.
        if not args.args:
            print("usage: bl LEVEL [FMT [CMD]]  (CMD defaults to 0x51)",
                file=sys.stderr)
            return 2
        level = int(args.args[0])
        fmt = int(args.args[1]) if len(args.args) > 1 else 0
        cmd = int(args.args[2]) if len(args.args) > 2 else 0x51
        #
        # The kernel answers with its own line when it has a backlight driver;
        # an empty answer is an unknown command, and printing a brightness
        # anyway reads as success (a kernel without the driver looked fine).
        #
        answer = simple(f"bl {level} {fmt} {cmd}")
        if not answer:
            print("no answer: this kernel has no backlight driver",
                file=sys.stderr)
            return 1
        print(answer.decode(errors="replace").strip())
        return 0
    if args.command in ("sr", "sw", "si", "sf", "smw", "sa", "sav", "keys", "blob",
                        "rtc", "execdeny", "gpukeep", "gpustat", "gpuperf", "temp", "tsens",
                        "thermal", "burn", "haps", "vib", "hapb", "hapv", "hapr", "hapw",
                        "spmimap", "kill", "say", "btuart"):
        answer = simple(" ".join([args.command] + list(args.args)))
        print(answer.decode(errors="replace").strip() if answer else "no answer")
        return 0
    if args.command == "wait":
        time.sleep(float(args.args[0]) if args.args else 1.0)
        return 0
    if args.command in ("del", "deltree", "ls"):
        answer = simple(" ".join([args.command] + list(args.args)))
        print(answer.decode(errors="replace").strip() if answer else "no answer")
        return 0
    if args.command in ("rr", "ww"):
        answer = simple(" ".join([args.command] + list(args.args)))
        print(answer.decode(errors="replace").strip() if answer else "no answer")
        return 0
    if args.command == "dcs":
        answer = simple("dcs " + " ".join(args.args))
        print(answer.decode(errors="replace").strip() if answer else "no answer")
        return 0
    if args.command == "rd":
        answer = simple("rd " + " ".join(args.args))
        print(answer.decode(errors="replace").strip() if answer else "no answer")
        return 0
    if args.command == "bcb":
        simple("bcb " + " ".join(args.args), 1.0)
        print("bcb " + " ".join(args.args))
        return 0
    if args.command == "tap":
        x, y = int(args.args[0]), int(args.args[1])
        touch(x, y, x, y, 0)
        print(f"tap {x},{y}")
        return 0
    if args.command == "swipe":
        x1, y1, x2, y2 = (int(v) for v in args.args[:4])
        ms = int(args.args[4]) if len(args.args) > 4 else 300
        touch(x1, y1, x2, y2, ms)
        print(f"swipe {x1},{y1} -> {x2},{y2} in {ms} ms")
        return 0
    if args.command == "key":
        code = int(args.args[0])
        down = args.args[1] not in ("up", "0", "false")
        key(code, down)
        print(f"key {code} {'down' if down else 'up'}")
        return 0
    if args.command == "poweroff":
        simple("poweroff", 5.0)
        print("poweroff sent")
        return 0
    if args.command == "respring":
        return respring()
    simple("reboot", 5.0)
    print("reboot sent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
