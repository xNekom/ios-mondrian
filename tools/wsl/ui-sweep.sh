#!/bin/bash
# Walk the screens a person sees first and capture each one, so a missing
# element is named from a picture instead of guessed from a report.
#
# Usage: ui-sweep.sh [OUT-PREFIX]
# Coordinates are panel pixels (1440x3200) from the captures this script writes.
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
PREF=${1:-out/sweep}

bash tools/wsl/attach.sh || exit 1
$RING bl 1024
$RING key 3 down >/dev/null; $RING key 3 up >/dev/null   # home
$RING wait 3
$RING screen "$PREF-home.png" || exit 1

# App Library: swipe left past the first home page.
$RING swipe 1200 1500 100 1500 260 >/dev/null
$RING wait 2
$RING swipe 1200 1500 100 1500 260 >/dev/null
$RING wait 3
$RING screen "$PREF-applibrary.png"

# Control Center from the top-right corner.
$RING swipe 1400 8 1400 1300 220 >/dev/null
$RING wait 4
$RING screen "$PREF-cc.png"
$RING tap 700 1900 >/dev/null   # dismiss
$RING wait 2

# Spotlight: pull down on the middle of the home screen.
$RING swipe 720 400 720 1500 260 >/dev/null
$RING wait 3
$RING screen "$PREF-spotlight.png"
$RING key 3 down >/dev/null; $RING key 3 up >/dev/null
$RING wait 2
echo "captures: $PREF-{home,applibrary,cc,spotlight}.png"
