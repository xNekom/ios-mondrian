#!/bin/bash
# Context around the newest "exec Spotlight" line: what the kernel logged before
# and after it (a load line would sit right there).
#
# Usage: ui-exec-context.sh PATTERN [BEFORE] [AFTER]
set -u
cd "$(dirname "$0")/../.." || exit 1
FILE=${FILE:-out/spot-bridge.txt}
PATTERN=${1:?usage: ui-exec-context.sh PATTERN [BEFORE] [AFTER]}
BEFORE=${2:-4}
AFTER=${3:-14}

n=$(grep -an "$PATTERN" "$FILE" | tail -1 | cut -d: -f1)
echo "== $PATTERN at line ${n:-none}"
if [ -n "${n:-}" ]; then
	sed -n "$((n - BEFORE)),$((n + AFTER))p" "$FILE"
fi
