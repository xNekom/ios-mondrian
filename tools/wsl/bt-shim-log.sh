#!/bin/bash
# bluetoothd's shim log, read to the end: the `_exit` interposer writes the
# status and a resolved backtrace there, which is the reason the daemon leaves.
# The file is truncated on each start, so the pid in the prefix says whether the
# read caught one run or two.
set -u
cd /mnt/c/Users/Pedro/Documents/GitHub/ios-mondrian || exit 1
LOG=/private/var/mobile/Library/Preferences/mondrian-btd.log

bash tools/wsl/attach.sh || exit 1

: > /tmp/btd.log
off=0
while [ "$off" -lt 200000 ]; do
	python3 tools/usb-ring.py rf "$LOG" "$off" 1000 > /tmp/btd-chunk.txt
	if head -c 2 /tmp/btd-chunk.txt | grep -q 'rf'; then
		[ "$off" = 0 ] && echo "missing $LOG"
		break
	fi
	n=$(wc -c < /tmp/btd-chunk.txt)
	cat /tmp/btd-chunk.txt >> /tmp/btd.log
	[ "$n" -lt 1000 ] && break
	off=$((off + n))
done

echo "== $(wc -c < /tmp/btd.log) bytes read"
echo "== pids in the log"
grep -a -o 'mondrian-bt\[[0-9]*\]' /tmp/btd.log | sort -u | tail -5
echo "== exit lines"
grep -a -i 'exit\|signal\|abort\|fatal' /tmp/btd.log | tail -12
echo "== tail"
tail -40 /tmp/btd.log
