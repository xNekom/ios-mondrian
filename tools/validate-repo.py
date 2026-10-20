#!/usr/bin/env python3
"""Validate repository integrity, patch sequences, and script syntax.

  tools/validate-repo.py [--verbose]

Checks:
  1. Patch sequence in xnu/patches/ and xnu/patches-mondrian/:
     - Sequential numbering starting at 0001 with no duplicates or gaps.
     - Patch files are non-empty and have valid unified diff markers.
  2. Python script syntax:
     - All tools/*.py compile cleanly via py_compile.
  3. Shell script syntax:
     - All tools/*.sh, shim/*.sh, and xnu/patches*/*.sh pass bash -n check.
"""
import argparse, glob, os, py_compile, re, subprocess, sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATCH_DIRS = ['xnu/patches', 'xnu/patches-mondrian']


def green(text): return f"\033[92m{text}\033[0m"
def red(text): return f"\033[91m{text}\033[0m"
def bold(text): return f"\033[1m{text}\033[0m"


def validate_patches(verbose=False):
    ok = True
    for patch_dir in PATCH_DIRS:
        full = os.path.join(REPO_ROOT, patch_dir)
        if not os.path.isdir(full):
            continue
        patch_files = sorted(glob.glob(os.path.join(full, '*.patch')))
        if not patch_files:
            print(red(f"[-] Error: No patch files found in {patch_dir}/"))
            ok = False
            continue

        errors = []
        seen_numbers = {}

        for path in patch_files:
            fname = os.path.basename(path)
            m = re.match(r'^(\d{4})-(.+)\.patch$', fname)
            if not m:
                errors.append(f"Invalid patch filename format: {fname}")
                continue

            num = int(m.group(1))
            if num in seen_numbers:
                errors.append(f"Duplicate patch number {num:04d}: {fname} and {seen_numbers[num]}")
            seen_numbers[num] = fname

            size = os.path.getsize(path)
            if size == 0:
                errors.append(f"Patch is empty: {fname}")
                continue

            with open(path, 'r', errors='ignore') as f:
                head = f.read(2048)
                if not ('--- ' in head or 'diff ' in head or 'Index:' in head):
                    errors.append(f"Patch missing standard diff header: {fname}")

        # Check contiguous sequence
        if seen_numbers:
            sorted_nums = sorted(seen_numbers.keys())
            expected = 1
            for num in sorted_nums:
                if num != expected:
                    errors.append(f"Gap in patch sequence: expected {expected:04d}, found {num:04d} ({seen_numbers[num]})")
                    expected = num + 1
                else:
                    expected += 1

        if errors:
            print(red(f"[-] Patch validation failed for {patch_dir}/ with {len(errors)} error(s):"))
            for err in errors:
                print(f"    - {err}")
            ok = False
        else:
            print(green(f"[✓] Validated {len(patch_files)} patches in {patch_dir}/ "
                        f"(0001-{len(patch_files):04d} contiguous, format OK)"))
    return ok


def validate_hunk_counts(verbose=False):
    """Check that every hunk header matches the lines it covers.

    A patch with a wrong count is "corrupt" for git apply, and the CI
    silently skips such a patch: the build then runs without it.
    """
    ok = True
    hunk_re = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')

    def check(hunk, rel):
        nonlocal ok
        if hunk is None:
            return
        if hunk['ao'] != hunk['oc'] or hunk['an'] != hunk['nc']:
            print(red(f"[-] {rel}: hunk at line {hunk['ln']} says -{hunk['oc']} +{hunk['nc']} "
                      f"but covers -{hunk['ao']} +{hunk['an']}"))
            ok = False

    for patch_dir in PATCH_DIRS:
        full = os.path.join(REPO_ROOT, patch_dir)
        if not os.path.isdir(full):
            continue
        for path in sorted(glob.glob(os.path.join(full, '*.patch'))):
            rel = os.path.relpath(path, REPO_ROOT)
            with open(path, 'r', errors='ignore') as f:
                lines = f.read().split('\n')
            hunk = None
            for ln, line in enumerate(lines, 1):
                m = hunk_re.match(line)
                if m:
                    check(hunk, rel)
                    hunk = {'ln': ln, 'oc': int(m.group(2) or 1), 'nc': int(m.group(4) or 1),
                            'ao': 0, 'an': 0}
                    continue
                if hunk is None:
                    continue
                if line.startswith('diff --git'):
                    check(hunk, rel)
                    hunk = None
                    continue
                if line.startswith('+') and not line.startswith('+++'):
                    hunk['an'] += 1
                elif line.startswith('-') and not line.startswith('---'):
                    hunk['ao'] += 1
                elif line.startswith(' '):
                    hunk['ao'] += 1
                    hunk['an'] += 1
            check(hunk, rel)
    if ok:
        print(green("[✓] Validated the hunk headers of every patch"))
    return ok


def validate_python_scripts(verbose=False):
    tools_dir = os.path.join(REPO_ROOT, 'tools')
    py_files = sorted(glob.glob(os.path.join(tools_dir, '*.py')))
    errors = []

    for path in py_files:
        fname = os.path.basename(path)
        try:
            py_compile.compile(path, doraise=True)
            if verbose:
                print(f"    [OK] {fname}")
        except py_compile.PyCompileError as e:
            errors.append(f"{fname}: {e}")

    if errors:
        print(red(f"[-] Python syntax validation failed with {len(errors)} error(s):"))
        for err in errors:
            print(f"    - {err}")
        return False

    print(green(f"[✓] Validated {len(py_files)} Python tools (syntax OK)"))
    return True


def validate_shell_scripts(verbose=False):
    sh_files = sorted(
        glob.glob(os.path.join(REPO_ROOT, 'tools/*.sh')) +
        glob.glob(os.path.join(REPO_ROOT, 'shim/*.sh')) +
        glob.glob(os.path.join(REPO_ROOT, 'xnu/patches*/*.sh'))
    )
    errors = []

    for path in sh_files:
        rel = os.path.relpath(path, REPO_ROOT)
        res = subprocess.run(['bash', '-n', path], capture_output=True, text=True)
        if res.returncode != 0:
            errors.append(f"{rel}: {res.stderr.strip()}")
        elif verbose:
            print(f"    [OK] {rel}")

    if errors:
        print(red(f"[-] Shell syntax validation failed with {len(errors)} error(s):"))
        for err in errors:
            print(f"    - {err}")
        return False

    print(green(f"[✓] Validated {len(sh_files)} Shell scripts (syntax OK)"))
    return True


def main():
    ap = argparse.ArgumentParser(description="Validate repository integrity, patches, and scripts.")
    ap.add_argument('-v', '--verbose', action='store_true', help='Show detailed per-file output')
    a = ap.parse_args()

    print(bold("=== Running ios-mondrian Repository Validation ==="))
    ok_patches = validate_patches(a.verbose)
    ok_hunks = validate_hunk_counts(a.verbose)
    ok_python = validate_python_scripts(a.verbose)
    ok_shell = validate_shell_scripts(a.verbose)

    if ok_patches and ok_hunks and ok_python and ok_shell:
        print(bold(green("\nAll repository integrity checks PASSED successfully!")))
        return 0
    else:
        print(bold(red("\nRepository integrity check FAILED.")))
        return 1


if __name__ == '__main__':
    sys.exit(main())
