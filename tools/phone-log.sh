#!/bin/sh
# Boot an image (optional) and collect the kernel's console ring, leaving the
# phone in the recovery.
#
#   tools/phone-log.sh OUT.txt             # just collect, from whatever state
#   tools/phone-log.sh IMAGE OUT.txt       # boot IMAGE first, then collect
#
# Why this exists: the phone has to be in three different states around one
# boot (loader -> the image -> recovery), and each one answers to a different
# tool. The loader's own fastboot loads a boot image; fastbootd, which the
# kernel's reset selects through the BCB command "boot-fastboot" (xnu 0133),
# answers "Unrecognized command boot" instead; and the ring is only readable
# from the recovery, which is the only place adb exists. `fastboot reboot
# recovery` leaves either loader mode. See NOTES.md for the retry budget that
# can also make `fastboot boot` refuse an image.
set -eu
cd "$(dirname "$0")/.."

ADB=${ADB:-adb}
FASTBOOT=${FASTBOOT:-fastboot}
SERIAL=${SERIAL:-}
if [ -n "$SERIAL" ]; then
	ADB="$ADB -s $SERIAL"
	FASTBOOT="$FASTBOOT -s $SERIAL"
fi

IMAGE=
if [ $# -gt 1 ]; then
	IMAGE=$1
	shift
fi
out=${1:?usage: phone-log.sh [IMAGE] OUT.txt}

in_loader() {
	$FASTBOOT devices 2>/dev/null | grep -q .
}
adb_state() {
	case "$($ADB devices 2>/dev/null | tr -d '\r' | awk 'NR==2{print $2}')" in
	recovery) echo recovery ;;
	device) echo android ;;
	*) echo none ;;
	esac
}
to_loader() {
	i=0
	while [ "$i" -lt 40 ]; do
		in_loader && return 0
		if [ "$(adb_state)" = recovery ]; then
			$ADB reboot bootloader >/dev/null 2>&1 || true
		fi
		sleep 3
		i=$((i + 1))
	done
	return 1
}
to_recovery() {
	i=0
	while [ "$i" -lt 40 ]; do
		[ "$(adb_state)" = recovery ] && return 0
		if in_loader; then
			$FASTBOOT reboot recovery >/dev/null 2>&1 || true
		fi
		sleep 3
		i=$((i + 1))
	done
	return 1
}

if [ -n "$IMAGE" ]; then
	[ -f "$IMAGE" ] || { echo "no hay imagen en $IMAGE" >&2; exit 1; }
	to_loader || { echo "no se alcanza el bootloader" >&2; exit 1; }
	# ABL spends one retry per boot and the port never reports a boot as
	# successful; when the budget is gone it refuses every image.
	slot=$($FASTBOOT getvar current-slot 2>&1 | tr -d '\r' | sed -n 's/^current-slot: *//p')
	if [ -n "$slot" ] &&
	   [ "$($FASTBOOT getvar "slot-unbootable:$slot" 2>&1 | tr -d '\r' |
		sed -n "s/^slot-unbootable:$slot: *//p")" = yes ]; then
		echo "== slot $slot no arrancable: fastboot set_active $slot"
		$FASTBOOT set_active "$slot" >/dev/null || true
	fi
	echo "== fastboot boot $IMAGE"
	$FASTBOOT boot "$IMAGE" 2>&1 | tr -d '\r' | grep -E 'Sending|Booting|FAILED' || true
	# the kernel resets itself (mondrianreset); fastbootd answers again
	i=0
	while [ "$i" -lt 60 ]; do
		in_loader && break
		sleep 4
		i=$((i + 1))
	done
	echo "== loader back"
fi

to_recovery || { echo "no se alcanza el recovery" >&2; exit 1; }
sleep 5
if [ -n "$SERIAL" ]; then
	exec sh tools/ios-log-pull.sh -s "$SERIAL" "$out"
fi
exec sh tools/ios-log-pull.sh "$out"
