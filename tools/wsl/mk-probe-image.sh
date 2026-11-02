#!/bin/bash
# Build the boot image with extra boot arguments that REPLACE the board's:
#   bash tools/wsl/mk-probe-image.sh "gpudstate=1"
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
extra=${1:-}
cmdline=$(python3 - "$extra" <<'PY'
import sys
sys.path.insert(0, 'tools')
import boards
line = boards.get_board('mondrian').cmdline.split()
drop = {a.split('=')[0] for a in sys.argv[1].split()}
line = [a for a in line if a.split('=')[0] not in drop]
print(' '.join(line + sys.argv[1].split()))
PY
) || exit 1
echo "== $cmdline"
python3 tools/mkpayload.py xnu/out/kernel.development.mondrian \
	shim/out/mondrian.adt shim/out/payload.bin --board mondrian \
	--cmdline "$cmdline" >/dev/null || exit 1
BOARD=mondrian DTB=dtb/mondrian-live.dtb EXTRA_CFLAGS=-DSHIM_NO_UFS \
	shim/build.sh shim/out/payload.bin >/dev/null 2>&1 || exit 1
echo "== image $(stat -c %s shim/out/shim-boot.img) bytes"
