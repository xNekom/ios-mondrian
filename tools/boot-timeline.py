#!/usr/bin/env python3
"""Print the boot timeline of a decoded mondrian console log.

The kernel ring has no timestamps, but the sampler prints "SMP t=Ns M procs"
every few seconds. Every other line is attributed to the last sample before
it, which is precise enough to see which phase owns the boot: the kernel
bring-up, the touch firmware load, or userland up to the first frame.

  tools/boot-timeline.py mondrian-console.log

The milestones are matched by substring; add one when a new subsystem gets
interesting.
"""
import re
import sys

MILESTONES = [
    ("touch bring-up", "MONDRIAN TOUCH: bring-up thread started"),
    ("touch firmware", "MONDRIAN TOUCH: firmware "),
    ("touch sections", "MONDRIAN TOUCH: section "),
    ("touch ready", "MONDRIAN TOUCH: report thread started"),
    ("root mounted", "hfs: mounted"),
    ("launchd exec", "exec launchd"),
    ("first swap", "MONDRIAN FB: swap 1 "),
    ("SpringBoard", "SBLockdownManager sharedInstance"),
    ("PosterBoard", "exec PosterBoard"),
]

SAMPLE = re.compile(r"SMP t=(\d+)s (\d+) procs")


def main(path):
    seen = set()
    at = None
    fps = []
    for line in open(path, errors="replace"):
        m = SAMPLE.search(line)
        if m:
            at = (int(m.group(1)), int(m.group(2)))
        if "MONDRIAN FB: fps " in line:
            m = re.search(r"fps (\d+)", line)
            if m:
                fps.append(int(m.group(1)))
        for name, needle in MILESTONES:
            if name in seen or needle not in line:
                continue
            seen.add(name)
            t, procs = at if at else (None, None)
            print(f"{name:15} t={t}s procs={procs}")
    if fps:
        tail = fps[-10:]
        print(f"fps last {len(tail)} samples: {tail} (max {max(fps)})")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
