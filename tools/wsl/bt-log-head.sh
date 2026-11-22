#!/bin/bash
# The shim power log's length and first lines. After a shim with the cap loads,
# the file starts with "log rotated"; a pull from offset 0 that stops at the
# first short answer is also how its length is measured (`pos` is the ring, not
# a file size).
#
# Usage: bt-log-head.sh [LINES]
set -u
cd "$(dirname "$0")/../.." || exit 1
LINES=${1:-3}
OUT=out/bt-log-head.log

bash tools/wsl/bt-read-log.sh \
	/private/var/mobile/Library/Preferences/mondrian-bt-power.log "$OUT" 0 |
	tail -1
head -"$LINES" "$OUT"
