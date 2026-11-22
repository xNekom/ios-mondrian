#!/bin/bash
# One app launch, counted from the ring: how many execs of NAME appeared, how
# many exits, and with which status. A tap that produces no exec never reached
# SpringBoard; an exec with a quick exit is the process being reaped.
#
# The wake trap is handled: the power key is a toggle, and a blanked panel eats
# the first touch and pays a ~17 s DCS panel-on, so the wake tap comes first and
# the launch tap only after the stall.
#
# Usage: ui-launch-ab.sh NAME X Y TAG
set -u
cd "$(dirname "$0")/../.." || exit 1
RING="python3 tools/usb-ring.py"
NAME=${1:?usage: ui-launch-ab.sh NAME X Y TAG}
X=${2:?}
Y=${3:?}
TAG=${4:-run}

bash tools/wsl/attach.sh || exit 1
$RING dump "out/ab-$TAG-before.txt" >/dev/null 2>&1
before=$(grep -ac "exec $NAME" "out/ab-$TAG-before.txt")
$RING tap 360 1000 >/dev/null
$RING wait 20 >/dev/null
$RING tap "$X" "$Y" >/dev/null
$RING wait 12 >/dev/null
$RING screen "out/ab-$TAG.png"
$RING dump "out/ab-$TAG-after.txt" >/dev/null 2>&1
after=$(grep -ac "exec $NAME" "out/ab-$TAG-after.txt")
echo "== $TAG: execs $before -> $after"
sed -n "$((before + 1)),\$p" "out/ab-$TAG-after.txt" |
	grep -a "exec $NAME\|exit $NAME\|CRASH $NAME\|denied $NAME" | head -8
