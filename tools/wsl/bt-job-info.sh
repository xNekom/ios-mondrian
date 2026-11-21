#!/bin/bash
# bluetoothd's plist, read in 1000-byte chunks (the control's rf caps a reply at
# that size) and parsed on the host.
set -u
cd /mnt/c/Users/Pedro/Documents/GitHub/ios-mondrian || exit 1
bash tools/wsl/attach.sh >/dev/null || exit 1
P=/System/Library/LaunchDaemons/com.apple.bluetoothd.plist
: > /tmp/bt-job.plist
for off in 0 1000 2000 3000 4000 5000 6000; do
	python3 tools/usb-ring.py rf "$P" "$off" 1000 > /tmp/bt-chunk.bin
	n=$(wc -c < /tmp/bt-chunk.bin)
	echo "offset $off -> $n bytes"
	cat /tmp/bt-chunk.bin >> /tmp/bt-job.plist
	[ "$n" -lt 1000 ] && break
done
python3 - <<'EOF'
import plistlib
data = open("/tmp/bt-job.plist", "rb").read()
print("total", len(data), "bytes")
try:
    job = plistlib.loads(data)
except Exception as exc:
    print("parse failed:", exc)
    print(data[-200:])
else:
    for key in ("Label", "Program", "ProgramArguments", "KeepAlive",
                "RunAtLoad", "StandardErrorPath", "StandardOutPath",
                "ThrottleInterval", "EnvironmentVariables"):
        if key in job:
            print(key, "=", job[key])
EOF
