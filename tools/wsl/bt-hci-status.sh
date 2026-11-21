#!/bin/bash
# Every HCI Command Complete in a ring dump, grouped by opcode, with the status
# bytes it carried. The control logs only the first 64 packets of a connection,
# but the refusals repeat, and a status is what separates "the command is not
# supported" (0x01), "invalid parameters" (0x12) and "command disallowed" (0x0c),
# which point at three different bugs.
#
# Usage: bt-hci-status.sh DUMP
set -u
DUMP=${1:?usage: bt-hci-status.sh DUMP}

python3 - "$DUMP" <<'PY'
import collections
import re
import sys

NAMES = {
    0x0c03: 'Reset', 0x0c1a: 'Write_Scan_Enable', 0x0c45: 'Write_Inquiry_Mode',
    0x1001: 'Read_Local_Version', 0x1002: 'Read_Local_Supported_Commands',
    0x1003: 'Read_Local_Supported_Features', 0x1004: 'Read_Local_Extended_Features',
    0x1005: 'Read_Buffer_Size', 0x1009: 'Read_BD_ADDR',
    0x2001: 'LE_Set_Event_Mask', 0x2002: 'LE_Read_Buffer_Size',
    0x2003: 'LE_Read_Local_Supported_Features',
    0x2005: 'LE_Set_Random_Address',
    0x2006: 'LE_Set_Advertising_Parameters',
    0x2008: 'LE_Set_Advertising_Data',
    0x200a: 'LE_Set_Advertising_Enable',
    0x200b: 'LE_Set_Scan_Parameters', 0x200c: 'LE_Set_Scan_Enable',
    0x200f: 'LE_Read_White_List_Size', 0x2010: 'LE_Clear_White_List',
    0x2016: 'LE_Read_Remote_Features',
    0xfce9: 'Apple_0xfce9', 0xfce2: 'Apple_0xfce2',
}
STATUS = {0x00: 'success', 0x01: 'unknown command', 0x0c: 'command disallowed',
          0x12: 'invalid parameters', 0x1a: 'unsupported feature'}

seen = collections.Counter()
pattern = re.compile(r'MONDRIAN BTCTL: rx \d+ 04 0e (.*)')
for line in open(sys.argv[1], 'r', errors='replace'):
    match = pattern.search(line)
    if not match:
        continue
    try:
        body = [int(b, 16) for b in match.group(1).split()]
    except ValueError:
        continue
    if len(body) < 4:
        continue
    # Command Complete: event len, num packets, opcode lo, opcode hi, status...
    opcode = body[2] | (body[3] << 8)
    status = body[4] if len(body) > 4 else None
    seen[(opcode, status)] += 1

print('opcode  name                             status                 count')
for (opcode, status), count in sorted(seen.items(), key=lambda kv: (-kv[1], kv[0])):
    label = '0x%02x %s' % (status, STATUS.get(status, '')) if status is not None else '-'
    print(' %#06x  %-32s %-22s %d' % (opcode, NAMES.get(opcode, ''), label, count))
PY
