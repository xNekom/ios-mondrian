#!/bin/bash
# Decode the names inside the HCI reports a ring dump carries: LE advertising
# reports (subevent 0x02), LE extended advertising reports (0x0d) and LE scan
# responses (0x04). Prints the address and the name each report carries, from
# the AD structure with type 0x08 or 0x09.
#
# Usage: bt-le-names.sh DUMP
set -u
DUMP=${1:?usage: bt-le-names.sh DUMP}

python3 - "$DUMP" <<'PY'
import re
import sys

pattern = re.compile(r'MONDRIAN BTCTL: (?:rx \d+ 04 3e|le adv|le scan rsp|le meta) (.*)')


def ad_name(data):
    i = 0
    while i + 1 < len(data):
        length = data[i]
        if length == 0:
            break
        kind = data[i + 1]
        value = data[i + 2:i + 1 + length]
        if kind in (0x08, 0x09) and value:
            return bytes(value).decode('utf-8', 'replace')
        i += 1 + length
    return None


def report(payload, kind):
    if kind == 'legacy' and len(payload) >= 12:
        addr = ':'.join('%02x' % b for b in reversed(payload[3:9]))
        dlen = payload[9]
        return addr, ad_name(payload[10:10 + dlen])
    if kind == 'extended' and len(payload) >= 27:
        addr = ':'.join('%02x' % b for b in reversed(payload[4:10]))
        dlen = payload[24]
        return addr, ad_name(payload[25:25 + dlen])
    return None, None


for line in open(sys.argv[1], 'r', errors='replace'):
    match = pattern.search(line)
    if not match:
        continue
    try:
        buf = [int(b, 16) for b in match.group(1).split()]
    except ValueError:
        continue
    # normalise: full packet (04 3e len ...) or payload (len ...) or subevent...
    if len(buf) > 2 and buf[0] == 0x04 and buf[1] == 0x3e:
        buf = buf[3:]
    elif len(buf) > 1 and buf[0] not in (0x02, 0x04, 0x0d) and \
            buf[1] in (0x02, 0x04, 0x0d):
        buf = buf[1:]
    if not buf:
        continue
    sub, payload = buf[0], buf[1:]
    if sub == 0x02:
        addr, name = report(payload, 'legacy')
        if addr:
            print('adv    %s %s' % (addr, name if name else '(no name)'))
    elif sub == 0x0d:
        addr, name = report(payload, 'extended')
        if addr:
            print('ext    %s %s' % (addr, name if name else '(no name)'))
PY
