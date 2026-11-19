#!/bin/bash
# Upload a test program and run it in the boot that is already up, then read
# what it printed.
#
#   tools/wsl/run-test.sh LOCAL [REMOTE] [ARGS...]
#
# The hook watches /private/var/vm/mondrian-run for the whole life of
# SpringBoard and spawns the line it reads (tools/mondrian-ui-hook.m,
# run_watcher). Writing that file is one wfile, so a test costs no boot; its
# stdout and stderr are /dev/console, which is the ring.
#
# The hook compares the line against the last one it ran, so the same command
# twice does nothing. A trailing token makes each run distinct; a program with
# `int main(void)` ignores it, and one that takes arguments should be given
# its own token in ARGS instead (`--run=7`).
set -e
[ $# -ge 1 ] || { echo "usage: run-test.sh LOCAL [REMOTE] [ARGS...]" >&2; exit 2; }
root=$(cd "$(dirname "$0")/../.." && pwd)
local_file=$1; shift
remote=${1:-/private/var/vm/$(basename "$local_file")}
[ $# -gt 0 ] && { shift; }
command_line="$remote $* run$RANDOM$RANDOM"
name=$(basename "$remote")

[ -f "$local_file" ] || { echo "run-test.sh: no $local_file" >&2; exit 1; }
echo "run-test.sh: $(stat -c %s "$local_file") bytes -> $remote"

cd "$root"
bash tools/wsl/attach.sh > /dev/null
python3 tools/usb-ring.py wfile "$remote" "$local_file"
printf '%s\n' "$command_line" > /tmp/mondrian-run.txt
python3 tools/usb-ring.py wfile /private/var/vm/mondrian-run /tmp/mondrian-run.txt
echo "run-test.sh: armed: $command_line"

# The watcher asks every two seconds; the run itself is what takes time. The
# ring already holds earlier runs' exit lines, so wait for the count to grow
# rather than for one to exist.
before=0
if python3 tools/usb-ring.py dump /tmp/mondrian-ring-before.txt > /dev/null 2>&1; then
	before=$(grep -ac 'MONDRIAN RUN: exit' /tmp/mondrian-ring-before.txt || true)
fi
for _ in $(seq 1 40); do
	sleep 5
	python3 tools/usb-ring.py dump /tmp/mondrian-ring.txt > /dev/null 2>&1 || continue
	now=$(grep -ac 'MONDRIAN RUN: exit' /tmp/mondrian-ring.txt || true)
	[ "${now:-0}" -gt "${before:-0}" ] && break
done
echo "== $name"
grep -a "$name" /tmp/mondrian-ring.txt | tail -40
echo "== exit lines"
grep -a 'MONDRIAN RUN: exit' /tmp/mondrian-ring.txt | tail -3
