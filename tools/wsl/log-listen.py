#!/usr/bin/env python3
"""Listen to the kernel's live console stream (udp/5140) for a few seconds.

    python3 tools/wsl/log-listen.py SECONDS OUTFILE

The kernel sends new console-ring bytes to 192.168.7.1:5140 every 100 ms while
`usblog` is on, which is the default. That stream is the only view of a phone
whose ring command port has stopped answering: a reset thread that hangs after
its last line is still sending the periodic sampler lines, and the last
`MONDRIAN REBOOT:`/`MONDRIAN RESET:` line in the capture says which step it
never got past.

The whole capture goes to OUTFILE; the matching lines are printed.
"""
import socket
import sys
import time

PORT = 5140


def main() -> int:
    secs = int(sys.argv[1]) if len(sys.argv) > 1 else 15
    out = sys.argv[2] if len(sys.argv) > 2 else "/root/log-listen.bin"

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", PORT))
    sock.settimeout(1.0)

    blob = bytearray()
    end = time.time() + secs
    while time.time() < end:
        try:
            data, _ = sock.recvfrom(65536)
        except socket.timeout:
            continue
        blob += data

    with open(out, "wb") as f:
        f.write(blob)

    text = blob.decode("latin-1", "replace")
    hits = [line for line in text.splitlines()
            if "MONDRIAN REBOOT" in line or "MONDRIAN RESET" in line
            or "MONDR USB" in line]
    print(f"log-listen: {len(blob)} bytes in {secs}s, {len(hits)} interesting lines")
    for line in hits[-8:]:
        print(f"  {line}")
    return 0 if blob else 1


if __name__ == "__main__":
    sys.exit(main())
