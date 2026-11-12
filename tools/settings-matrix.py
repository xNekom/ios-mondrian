#!/usr/bin/env python3
"""Drive a matrix of Settings experiments in one boot, with the ring as the record.

A boot on this port costs minutes, so a run is a sequence of steps and each step
labels its own log lines: the step is written to the kernel ring ("say") before
the action, the action is one of the host-side controls, and the whole ring is
dumped once at the end and split on the marks. One boot answers a matrix of
questions instead of one.

  tools/settings-matrix.py tap 720 1500 \\
      --step mark "General" tap 700 640 \\
      --step cfg empty tap 700 520 \\
      --step cfg pass --step killname locationd \\
      --step tap 700 520 --dump matrix-ring.txt

Steps, in order (each one marked before it runs):

  tap X Y              one touch, panel pixels (1440x3200)
  swipe X1 Y1 X2 Y2 [MS]
  key CODE down|up     0 power, 1 volume up, 2 volume down, 3 home
  sleep SECONDS
  mark TEXT            a label of its own (for a control run)
  cfg MODE             rewrite the probe's variant (pass, empty, error,
                       delay 5, off) over "wfile"; the probe rereads it on the
                       next call, so no restart and no boot
  kill PID
  killname NAME        resolve the pid from the sampler's last "SMP" line
                       (mondriansample=NAME,... must include it)

The probe (tools/mondrian-probe.m) logs "MONDRIAN PROBE:" lines; this tool only
marks and splits, so it works the same with the probe absent (the marks then
carry nothing but the crash and exec lines between them).
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
USB_RING = os.path.join(HERE, 'usb-ring.py')
PROBE_CFG = '/private/var/vm/mondrian-probe.cfg'
MARK = 'MONDRIAN MARK: '


def run(*args, check=False):
    p = subprocess.run([sys.executable, USB_RING] + list(args),
                       capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.exit(f'{args[0]} failed: {p.stdout}{p.stderr}')
    return (p.stdout + p.stderr).strip()


def mark(text):
    run('say', text)


def sampler_pid(name, ring_text=None):
    """The pid the kernel sampler printed for NAME, from the newest SMP line."""
    text = ring_text if ring_text is not None else run('dump', '-')
    if not text:
        return None
    found = None
    for line in text.splitlines():
        if not line.startswith('SMP '):
            continue
        for m in re.finditer(r'\| (\S+?)\((\d+)\)', line):
            if m.group(1) == name:
                found = int(m.group(2))
    return found


def write_cfg(mode):
    fd, path = tempfile.mkstemp(prefix='mondrian-cfg-')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(mode.strip() + '\n')
        return run('wfile', PROBE_CFG, path)
    finally:
        os.unlink(path)


def do_step(step, args, ring):
    kind, rest = step, args
    if kind == 'mark':
        mark(' '.join(rest))
        return True
    if kind == 'tap':
        x, y = rest[0], rest[1]
        mark(f'tap {x} {y}')
        run('tap', x, y)
        return True
    if kind == 'swipe':
        mark(' '.join(rest))
        run('swipe', *rest)
        return True
    if kind == 'key':
        mark(' '.join(rest))
        run('key', *rest)
        return True
    if kind == 'sleep':
        mark(f'sleep {rest[0]}')
        time.sleep(float(rest[0]))
        return True
    if kind == 'cfg':
        mode = ' '.join(rest)
        mark(f'cfg {mode}')
        print(write_cfg(mode))
        return True
    if kind == 'kill':
        mark(f'kill {rest[0]}')
        print(run('kill', rest[0]))
        return True
    if kind == 'killname':
        pid = sampler_pid(rest[0], ring)
        if pid is None:
            print(f'killname {rest[0]}: no pid in the sampler line',
                  file=sys.stderr)
            return False
        mark(f'kill {rest[0]} {pid}')
        print(run('kill', str(pid)))
        return True
    print(f'unknown step: {kind}', file=sys.stderr)
    return False


def slice_ring(ring, dump_path):
    """Print the ring split on the marks, in order."""
    chunks = []
    current = ['(before the first mark)']
    for line in ring.splitlines():
        at = line.find(MARK)
        if at >= 0:
            chunks.append(current)
            current = [line[at + len(MARK):]]
            continue
        current.append(line)
    chunks.append(current)
    for chunk in chunks:
        body = [line.rstrip() for line in chunk[1:] if line.strip()]
        if not body and chunk[0] in ('', '(before the first mark)'):
            continue
        print(f'\n===== {chunk[0].rstrip()}')
        for line in body:
            print(f'  {line}')
    if dump_path:
        with open(dump_path, 'w') as f:
            f.write(ring)
        print(f'\nring written to {dump_path}')


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--step', nargs='+', action='append', metavar='STEP',
                    help='a step: tap X Y, cfg MODE, killname NAME, ...')
    ap.add_argument('--dump', help='write the whole ring here after the run')
    ap.add_argument('--settle', type=float, default=1.5,
                    help='seconds to wait after each action (default 1.5)')
    a = ap.parse_args()

    if not a.step:
        ap.print_help()
        return 2

    ring = run('dump', '-')
    if not ring:
        print('no ring: is the gadget up (usb=2) and the host on 192.168.7.1?',
              file=sys.stderr)
        return 1

    print(f'{len(ring.splitlines())} ring lines before the run')
    for step in a.step:
        ok = do_step(step[0], step[1:], ring)
        if not ok:
            return 1
        time.sleep(a.settle)

    time.sleep(2.0)
    ring = run('dump', '-')
    slice_ring(ring, a.dump)
    return 0


if __name__ == '__main__':
    sys.exit(main())
