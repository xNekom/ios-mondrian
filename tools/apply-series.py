#!/usr/bin/env python3
"""Apply a patch series to an xnu tree and report what does not apply.

  tools/apply-series.py TREE [--series xnu/patches-mondrian] [--check]

The CI does the same thing with `git apply` inside the build script, but a
run takes minutes and the failures are buried in a log. This does it in
seconds, so a port can be iterated patch by patch without a CI run.

The tree has to be the xnu the series was written against (xnu-8796.141.3 for
the iOS 16 generation):

  git clone --depth 1 --branch xnu-8796.141.3 \\
      https://github.com/apple-oss-distributions/xnu.git xnu8796

The staging scripts of the series (the *.sh files that fetch Apple's open
source libpthread, HFS and BearSSL) run first, like the build script does.
With --check nothing is written, the patches are only tested.
"""
import argparse
import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def stage(tree, series, machine, macos):
    """Run the staging scripts of the series in the tree."""
    scripts = sorted(s for s in os.listdir(series) if s.endswith('.sh'))
    if not scripts:
        return True
    env = dict(os.environ, MACHINE_CONFIG=machine, MACOS_VERSION=macos)
    for name in scripts:
        path = os.path.join(series, name)
        print(f'stage {name}')
        p = subprocess.run(['bash', path], cwd=tree, env=env, capture_output=True, text=True)
        if p.returncode:
            for line in (p.stdout + p.stderr).strip().splitlines():
                print(f'     {line}')
            print(f'FAIL {name}')
            return False
    return True


def apply_one(tree, path, check):
    cmd = ['git', '-C', tree, 'apply']
    cmd.append('--check' if check else '--reject')
    if not check:
        cmd.append('--verbose')
    cmd += ['--whitespace=nowarn', path]
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tree', help='an xnu source tree')
    ap.add_argument('--series', default='xnu/patches-mondrian',
                    help='patch directory, relative to the repository (default: the mondrian series)')
    ap.add_argument('--check', action='store_true', help='do not write, only test')
    ap.add_argument('--stop', action='store_true', help='stop at the first failure')
    ap.add_argument('--machine', default='SWEET',
                    help='MACHINE_CONFIG for the staging scripts (default: SWEET)')
    ap.add_argument('--macos', default='13.5',
                    help='MACOS_VERSION for the staging scripts (default: 13.5)')
    ap.add_argument('--no-stage', action='store_true', help='do not run the staging scripts')
    a = ap.parse_args()

    series = a.series if os.path.isabs(a.series) else os.path.join(REPO_ROOT, a.series)
    if not os.path.isdir(series):
        raise SystemExit(f'no such series: {series}')
    if not os.path.isdir(os.path.join(a.tree, '.git')):
        raise SystemExit(f'{a.tree} is not a git tree')

    if not a.no_stage and not stage(a.tree, series, a.machine, a.macos):
        raise SystemExit('the staging scripts failed')

    patches = sorted(p for p in os.listdir(series) if p.endswith('.patch'))
    if not patches:
        raise SystemExit(f'no patches in {series}')

    failed = []
    for name in patches:
        path = os.path.join(series, name)
        rc, out = apply_one(a.tree, path, a.check)
        if rc:
            failed.append(name)
            print(f'FAIL {name}')
            for line in out.splitlines():
                print(f'     {line}')
            if a.stop:
                break
        else:
            print(f'ok   {name}')

    print(f'\n{len(patches) - len(failed)}/{len(patches)} patches applied'
          f'{" (check only)" if a.check else ""}')
    if failed:
        print('failed: ' + ', '.join(failed))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
