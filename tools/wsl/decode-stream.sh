#!/bin/bash
# Extract one dumped PM4 stream from the ring and name its packets.
#
#   tools/wsl/decode-stream.sh RING.txt STREAM_NUMBER
#
# The kernel dumps the first streams of a submission as
# "MondrianGPU: pm4 <offset> <8 hex words>" lines (0182); Mesa's own opcode
# names come from adreno_pm4.xml through tools/pm4-decode.py.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ring=${1:?usage: decode-stream.sh RING.txt STREAM}
which=${2:-1}
mkdir -p /root/streams
out=/root/streams/stream-$which.txt

awk -v w="$which" '
	/^MondrianGPU: pm4 stream [0-9]+ size/ {
		n = $4; on = (n == w)
		if (on) { want = $6 / 4; left = want }
		next
	}
	/^MondrianGPU: pm4 / {
		if (on && left > 0) {
			for (i = 4; i <= NF && left > 0; i++) { print $i; left-- }
		}
	}
' "$ring" >"$out"
words=$(wc -w <"$out")
echo "== stream $which: $words words"
[ "$words" -gt 0 ] || exit 1
python3 tools/pm4-decode.py -x out/mesa/mesa-25.0.7/src/freedreno/registers/adreno/adreno_pm4.xml "$out"
