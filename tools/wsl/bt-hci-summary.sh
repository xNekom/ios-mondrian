#!/bin/bash
# Tally the HCI packets the kernel control logged in a ring dump. The control
# logs only the first 64 packets of each connection, so a count is what tells
# whether a command was ever sent and whether its event ever came back; the
# bytes of one line are not enough.
#
# Usage: bt-hci-summary.sh DUMP
set -u
DUMP=${1:?usage: bt-hci-summary.sh DUMP}

python3 - "$DUMP" <<'PY'
import collections
import re
import sys

COMMANDS = {
    0x0401: 'Inquiry',
    0x0402: 'Inquiry_Cancel',
    0x0405: 'Create_Connection',
    0x0419: 'Remote_Name_Request',
    0x041b: 'Read_Remote_Supported_Features',
    0x0c03: 'Reset',
    0x0c05: 'Set_Event_Mask',
    0x0c14: 'Read_Local_Name',
    0x0c1a: 'Write_Scan_Enable',
    0x0c24: 'Write_Class_of_Device',
    0x0c33: 'Read_Local_Supported_Commands',
    0x0c45: 'Write_Inquiry_Mode',
    0x0c52: 'Write_Extended_Inquiry_Response',
    0x0c56: 'Write_LE_Host_Support',
    0x0c6d: 'Write_LE_White_List_Size?',
    0x2002: 'LE_Read_Buffer_Size',
    0x2005: 'LE_Set_Event_Mask',
    0x2006: 'LE_Read_White_List_Size',
    0x2008: 'LE_Clear_White_List',
    0x200b: 'LE_Read_White_List_Size?',
    0x200c: 'LE_Set_Scan_Parameters',
    0x200d: 'LE_Set_Scan_Enable',
    0x2016: 'LE_Read_Remote_Features',
    0xfce9: 'Apple 0xfce9',
    0xfce2: 'Apple 0xfce2',
}
EVENTS = {
    0x02: 'Inquiry_Result',
    0x03: 'Conn_Complete',
    0x05: 'Disconn_Complete',
    0x0e: 'Command_Complete',
    0x0f: 'Command_Status',
    0x13: 'Number_Of_Completed_Packets',
    0x2f: 'Inquiry_Result_with_RSSI',
    0x3e: 'LE_Meta',
}

commands = collections.Counter()
events = collections.Counter()
le_meta = collections.Counter()
connects = 0
pattern = re.compile(r'MONDRIAN BTCTL: (connected|tx|rx) (.*)')
for line in open(sys.argv[1], 'r', errors='replace'):
    match = pattern.search(line)
    if not match:
        continue
    what, rest = match.groups()
    if what == 'connected':
        connects += 1
        continue
    try:
        parts = [int(b, 16) for b in rest.split()]
    except ValueError:
        continue
    if len(parts) < 2:
        continue
    if what == 'tx' and parts[1] == 0x01 and len(parts) >= 4:
        opcode = parts[2] | (parts[3] << 8)
        commands[opcode] += 1
    elif what == 'rx' and parts[1] == 0x04 and len(parts) >= 3:
        code = parts[2]
        events[code] += 1
        if code == 0x3e and len(parts) >= 4:
            le_meta[parts[3]] += 1

print('connections logged: %d' % connects)
print('commands:')
for opcode, count in commands.most_common():
    print('  %#06x %-28s %d' % (opcode, COMMANDS.get(opcode, ''), count))
print('events:')
for code, count in events.most_common():
    print('  %#04x %-28s %d' % (code, EVENTS.get(code, ''), count))
print('LE meta subevents:')
for sub, count in le_meta.most_common():
    print('  %#04x %d' % (sub, count))
PY
