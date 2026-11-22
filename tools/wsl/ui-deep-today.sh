#!/bin/bash
# Dump the view/layer tree of the open Today view from SpringBoard, so the four
# 192x192 suggestion cards get a class name instead of a guess.
#
# The hook walks the HomeScreenWindow when /private/var/vm/mondrian-deep holds a
# new number (four dumps per process, docs/UI_PERFORMANCE.md).
#
# Usage: ui-deep-today.sh [NUMBER]
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
N=${1:-7}

bash tools/wsl/attach.sh || exit 1
$RING bl 1024 >/dev/null
$RING key 3 down >/dev/null; $RING key 3 up >/dev/null
$RING wait 2
$RING swipe 720 400 720 1500 260 >/dev/null
$RING wait 5

printf '%s\n' "$N" > out/deep-ask.txt
$RING wfile /private/var/vm/mondrian-deep out/deep-ask.txt >/dev/null || exit 1
$RING wait 5
$RING screen out/deep-today.png
$RING dump out/deep-today.txt >/dev/null 2>&1

echo "== dump"
grep -a 'MONDRIAN DEEP:' out/deep-today.txt | tail -60
