#!/bin/bash
# Estimate how long a process lived from the ring. The ring has no timestamps,
# but it carries one-second and periodic lines (SpringBoard's `ca begin`, the
# memory and battery reports, the compositor's `rate`), so counting those
# between `exec NAME` and `exit NAME` dates the death well enough to tell a
# launch watchdog (~20 s) from an immediate kill.
#
# Usage: ring-lifetime.sh FILE NAME
set -u
FILE=${1:?usage: ring-lifetime.sh FILE NAME}
NAME=${2:?}

a=$(grep -an "exec $NAME" "$FILE" | tail -1 | cut -d: -f1)
b=$(grep -an "exit $NAME" "$FILE" | tail -1 | cut -d: -f1)
if [ -z "${a:-}" ] || [ -z "${b:-}" ]; then
	echo "no exec/exit pair for $NAME" >&2
	exit 1
fi
echo "== $NAME: exec at line $a, exit at line $b"
awk -v a="$a" -v b="$b" 'NR > a && NR < b &&
	/ca begin|MONDRIAN MEM|MONDRIAN BATT|MONDRIAN DL\[|mondrian-gl: rate|heartbeat/' "$FILE"
echo "== total lines between: $((b - a))"
