#!/bin/bash
# Extract one nested indirect-buffer dump from the ring and name its packets.
#
#   tools/wsl/decode-nested.sh RING.txt ADDRESS     # e.g. 0x10434000
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ring=${1:?usage: decode-nested.sh RING.txt ADDRESS}
addr=${2:?usage: decode-nested.sh RING.txt ADDRESS}
addr=${addr#0x}
mkdir -p /root/streams
out=/root/streams/nested-$addr.txt

awk -v a="$addr" '
	/^MondrianGPU: nested ib 0x[0-9a-f]+ [0-9]+ dwords/ {
		got = ($4 == "0x" a); left = got ? $5 : 0; next
	}
	/^MondrianGPU: pm4 / {
		if (got && left > 0) {
			for (i = 4; i <= NF && left > 0; i++) { print $i; left-- }
		}
	}
' "$ring" >"$out"

words=$(wc -w <"$out")
echo "== nested 0x$addr: $words words"
[ "$words" -gt 0 ] || exit 1
python3 tools/pm4-decode.py -x out/mesa/mesa-25.0.7/src/freedreno/registers/adreno/adreno_pm4.xml "$out" | tail -25
