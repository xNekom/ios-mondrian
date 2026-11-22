#!/bin/bash
# Print the lines of a saved ring around the last match of a pattern. The ring
# is the only trace of a process's life on this port, so "what happened around
# exit X" is the routine question; doing it with grep -n and sed inline keeps
# running into shell quoting.
#
# Usage: ring-window.sh FILE PATTERN [BEFORE] [AFTER]
set -u
FILE=${1:?usage: ring-window.sh FILE PATTERN [BEFORE] [AFTER]}
PAT=${2:?}
BEFORE=${3:-20}
AFTER=${4:-10}

line=$(grep -an -- "$PAT" "$FILE" | tail -1 | cut -d: -f1)
if [ -z "${line:-}" ]; then
	echo "no match for '$PAT' in $FILE" >&2
	exit 1
fi
first=$((line - BEFORE))
[ "$first" -lt 1 ] && first=1
echo "== '$PAT' at line $line, showing $first..$((line + AFTER))"
sed -n "${first},$((line + AFTER))p" "$FILE"
