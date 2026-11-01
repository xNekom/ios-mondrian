#!/usr/bin/env bash
# Read the kernel's console ring out of the phone (recovery + adb) and decode it.
#
#   tools/wsl/pull-ring.sh out.txt
#
# Same read as tools/ios-log-pull.sh, but it finds the Windows adb.exe when
# running inside WSL, where the USB device is only visible to the Windows adb.
# Only reads the last 4 MiB of userdata.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ -z "${ADB:-}" ]; then
	for candidate in adb /mnt/c/platform-tools/adb.exe "$(command -v adb 2>/dev/null || true)"; do
		[ -n "$candidate" ] && command -v "$candidate" >/dev/null 2>&1 && { ADB=$candidate; break; }
	done
fi
[ -n "${ADB:-}" ] || { echo "error: no adb (set ADB=...)" >&2; exit 1; }

out=${1:?usage: pull-ring.sh OUT.txt}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ring.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

dev=$($ADB shell 'for d in /dev/block/by-name/userdata /dev/block/bootdevice/by-name/userdata; do [ -e $d ] && readlink -f $d && break; done' | tr -d '\r')
[ -n "$dev" ] || { echo "error: userdata not found (is the phone in recovery with adb?)" >&2; exit 1; }
bytes=$($ADB shell "blockdev --getsize64 $dev" | tr -d '\r')
skip=$(( bytes / 4096 - 1025 ))
echo "== $dev: $bytes bytes, reading blocks $skip..$((skip + 1024))" >&2
$ADB exec-out "dd if=$dev bs=4096 skip=$skip count=1025 2>/dev/null" >"$tmp/ring.bin"
python3 tools/ios-log.py "$tmp/ring.bin" "$out"
wc -l "$out"
