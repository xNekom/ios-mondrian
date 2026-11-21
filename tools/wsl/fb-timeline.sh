#!/bin/bash
# Where did the display stop presenting? Prints the last frame-rate sample that
# was not zero and the ring lines around it, so the event that took the scanout
# down (a blank, a surface destroy, a commit with no layers) shows itself.
#
# Usage: fb-timeline.sh DUMP
set -u
DUMP=${1:?usage: fb-timeline.sh DUMP}

echo "== fps samples"
grep -n 'MONDRIAN FB: fps' "$DUMP" | head -3
grep -n 'MONDRIAN FB: fps' "$DUMP" | tail -3

last=$(grep -n 'MONDRIAN FB: fps [1-9]' "$DUMP" | tail -1 | cut -d: -f1)
if [ -z "$last" ]; then
	echo "== no non-zero sample in this dump"
	exit 0
fi
echo "== last presenting sample at line $last"
start=$((last - 8))
[ "$start" -lt 1 ] && start=1
sed -n "${start},$((last + 20))p" "$DUMP"
