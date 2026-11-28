#!/usr/bin/env python3
"""Check the repository the way AGENTS.md says it must be checked.

Every check has an id (R01, R03..R09). AGENTS.md carries the same ids in its
"Repository checks" table and this script fails when the two disagree: a rule
that is only prose is a red build, not a wish.

  tools/check-agent.py              run every check
  tools/check-agent.py --only R03   run one check
  tools/check-agent.py --list       print the ids
  tools/check-agent.py --verbose    per-file detail

Exit status 1 when any check fails.
"""
import argparse
import glob
import importlib.util
import math
import os
import re
import subprocess
import sys

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding='utf-8')
    except (AttributeError, ValueError):
        pass

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TEXT_EXT = {'.md', '.py', '.sh', '.c', '.h', '.m', '.S', '.s', '.pyi',
            '.toml', '.yml', '.yaml', '.json', '.txt', '.patch', '.diff',
            '.plist', '.entitlements', '.cfg', '.conf', '.gitignore',
            '.gitattributes'}
BINARY_EXT = {'.png', '.jpg', '.jpeg', '.gif', '.bin', '.img', '.dmg', '.zip',
              '.gz', '.lz4', '.elf', '.kext', '.woff', '.ttf', '.pdf'}
CAPTURE_NAMES = {'ring.bin', 'ring.txt'}
CAPTURE_EXT = {'.bin', '.img', '.dmp', '.core', '.tap'}
SECRET_RES = [
    (re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'), 'private key block'),
    (re.compile(r'sshpass\s+-p\s+(?!<)\S+'), 'sshpass with a literal password'),
    (re.compile(r'(?i)password\s*[:=]\s*(?!<)\S{6,}'), 'literal password'),
    (re.compile(r'\bAKIA[0-9A-Z]{16}\b'), 'AWS access key id'),
    (re.compile(r'\bghp_[A-Za-z0-9]{36}\b'), 'GitHub token'),
]


def tracked():
    out = subprocess.run(['git', '-C', REPO, 'ls-files', '-z'],
                         capture_output=True, check=True).stdout
    for raw in out.split(b'\0'):
        if raw:
            yield raw.decode('utf-8', 'surrogateescape')


def read(rel):
    try:
        with open(os.path.join(REPO, rel), 'r', encoding='utf-8',
                  errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def is_text(rel):
    ext = os.path.splitext(rel)[1].lower()
    if ext in BINARY_EXT:
        return False
    if ext in TEXT_EXT:
        return True
    if os.path.basename(rel) in ('.gitignore', '.gitattributes'):
        return True
    return ext == ''


def check_doc_links(verbose=False):
    """R01: every relative link in the docs resolves."""
    files = ['README.md', 'NOTES.md', 'AGENTS.md']
    docs = os.path.join(REPO, 'docs')
    if os.path.isdir(docs):
        files += ['docs/' + n for n in sorted(os.listdir(docs))
                  if n.endswith('.md')]
    problems, seen = [], 0
    link = re.compile(r'\[[^\]]*\]\(([^)]+)\)')
    for rel in files:
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            problems.append(f'{rel}: missing')
            continue
        text = read(rel)
        for m in link.finditer(text):
            target = m.group(1).strip().split('#')[0].strip()
            if not target or target.startswith(('http://', 'https://',
                                                'mailto:', '/')):
                continue
            seen += 1
            resolved = os.path.normpath(os.path.join(REPO,
                                                     os.path.dirname(rel),
                                                     target))
            if not os.path.exists(resolved):
                problems.append(f'{rel}: dead link -> {target}')
    return not problems, f'{seen} relative links', problems


def check_line_endings(verbose=False):
    """R03: no tracked text file carries CRLF."""
    problems = []
    for rel in tracked():
        path = os.path.join(REPO, rel)
        if not is_text(rel) or not os.path.isfile(path):
            continue
        try:
            with open(path, 'rb') as f:
                data = f.read()
        except OSError:
            continue
        if b'\0' in data[:4096]:
            continue
        if b'\r\n' in data:
            problems.append(rel)
    detail = ', '.join(problems[:6]) + (' ...' if len(problems) > 6 else '')
    return not problems, 'LF only' if not problems else detail, problems


def check_captures(verbose=False):
    """R04: device captures and images stay out of git."""
    problems = []
    for rel in tracked():
        base = os.path.basename(rel)
        ext = os.path.splitext(rel)[1].lower()
        if base in CAPTURE_NAMES or (base.startswith('usb-') and
                                     base.endswith('.txt')):
            problems.append(f'{rel}: device capture')
        elif ext in CAPTURE_EXT:
            problems.append(f'{rel}: binary artifact ({ext})')
    return not problems, 'no device captures tracked', problems


def check_secrets(verbose=False):
    """R05: no credentials in first-party files."""
    problems = []
    for rel in tracked():
        if not is_text(rel) or rel.startswith(('xnu/', 'research/')):
            continue
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path) or os.path.getsize(path) > 2 << 20:
            continue
        text = read(rel)
        for pattern, what in SECRET_RES:
            if pattern.search(text):
                problems.append(f'{rel}: {what}')
    return not problems, 'no credentials', problems


def load_boards():
    path = os.path.join(REPO, 'tools', 'boards.py')
    spec = importlib.util.spec_from_file_location('boards_under_test', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.BOARDS


def board_defines():
    """The `#define`s of shim/board.h, split by board."""
    text = read('shim/board.h')
    mondrian = sweet = ''
    m = re.search(r'#if defined\(BOARD_MONDRIAN\)(.*?)'
                  r'#else\s*/\* BOARD_SWEET(.*?)'
                  r'#endif\s*/\* BOARD_MONDRIAN', text, re.S)
    if m:
        mondrian, sweet = m.group(1), m.group(2)
    else:
        return {}

    def parse(block):
        out = {}
        for name, value in re.findall(r'^#define\s+(\w+)\s+([^\s]+)',
                                      block, re.M):
            out[name] = value
        return out

    shared = {}
    tail = text[m.end():] if m else ''
    for name, value in re.findall(r'^#define\s+(\w+)\s+([^\s]+)',
                                  tail, re.M):
        shared[name] = value
    return {'mondrian': parse(mondrian), 'sweet': parse(sweet),
            'shared': shared}


def as_int(value):
    v = re.sub(r'[uUlL]+$', '', value)
    return int(v, 0)


def as_text(value):
    return value.strip('"')


BOARD_MAP = [
    ('BOARD_NAME', 'name', 'text'),    ('BOARD_SOC', 'soc', 'text'),
    ('GICD_BASE', 'gicd', 'int'),
    ('GICR_BASE', 'gicr', 'int'),
    ('GICR_SIZE', 'gicr_size', 'int'),
    ('GICR_PE_SIZE', 'gicr_pe_size', 'int'),
    ('VTIMER_INTID', 'vtimer_intid', 'int'),
    ('SGI_INTID', 'ipi_sgi', 'int'),
    ('BOARD_MEM_BASE', 'phys_base', 'int'),
    ('BOARD_MEM_SIZE', 'mem_size', 'int'),
    ('UFS_BASE', 'ufs', 'int'),
    ('FB_BASE', 'fb', 'int'),
    ('FB_SIZE', 'fb_size', 'int'),
    ('FB_W', 'fb_w', 'int'),
    ('FB_H', 'fb_h', 'int'),
    ('PAYLOAD_MAGIC', 'payload_magic', 'magic'),
    ('NR_CPUS', 'cpus', 'len'),
    ('BOARD_BOOT_CORE', 'boot_core', 'int'),
]

# On sweet the device tree always names the kernel window, so board.h carries
# 0 as "no fallback" rather than a number that must equal boards.py.
NO_FALLBACK = {'sweet': {'BOARD_MEM_BASE', 'BOARD_MEM_SIZE'}}


def check_board_sync(verbose=False):
    """R06: tools/boards.py and shim/board.h carry the same numbers."""
    try:
        boards = load_boards()
    except Exception as exc:                      # noqa: BLE001 - report it
        return False, 'boards.py did not import', [str(exc)]
    defines = board_defines()
    if not defines:
        return False, 'shim/board.h not parsed', \
            ['shim/board.h: expected the BOARD_MONDRIAN/BOARD_SWEET split']
    problems = []
    for name, board in sorted(boards.items()):
        d = dict(defines.get('shared', {}))
        d.update(defines.get(name, {}))
        if not d:
            problems.append(f'shim/board.h: no defines for {name}')
            continue
        for define, attr, kind in BOARD_MAP:
            if define not in d:
                problems.append(f'{name}: {define} missing in board.h')
                continue
            expected = getattr(board, attr)
            raw = d[define]
            try:
                if kind == 'int' and define in NO_FALLBACK.get(name, ()) \
                        and as_int(raw) == 0:
                    continue
                if kind == 'int':
                    actual, expected = as_int(raw), int(expected)
                elif kind == 'text':
                    actual, expected = as_text(raw), str(expected)
                elif kind == 'magic':
                    actual, expected = as_text(raw).encode(), bytes(expected)
                else:
                    actual, expected = as_int(raw), len(expected)
            except (TypeError, ValueError):
                problems.append(f'{name}: {define} is not a literal ({raw})')
                continue
            if actual != expected:
                got = f'0x{actual:x}' if kind == 'int' else actual
                want = f'0x{expected:x}' if kind == 'int' else expected
                problems.append(f'{name}: {define}={got}, boards.py says '
                                f'{want}')
        shift = d.get('BOARD_PG_SHIFT')
        if shift is None:
            problems.append('shim/board.h: BOARD_PG_SHIFT missing')
        elif as_int(shift) != int(math.log2(board.page_size)):
            problems.append(f'{name}: BOARD_PG_SHIFT={shift}, boards.py page '
                            f'size {board.page_size}')
    return not problems, f'{len(boards)} boards compared', problems


def check_skills(verbose=False):
    """R07: each project skill has front matter naming its own directory."""
    root = os.path.join(REPO, '.github', 'skills')
    if not os.path.isdir(root):
        return False, 'no skills directory', ['.github/skills/ missing']
    problems, count = [], 0
    for entry in sorted(os.listdir(root)):
        skill = os.path.join(root, entry, 'SKILL.md')
        if not os.path.isfile(skill):
            problems.append(f'{entry}: SKILL.md missing')
            continue
        count += 1
        text = read(f'.github/skills/{entry}/SKILL.md')
        m = re.match(r'---\n(.*?)\n---', text, re.S)
        if not m:
            problems.append(f'{entry}: no YAML front matter')
            continue
        front = m.group(1)
        name = re.search(r'^name:\s*(\S+)', front, re.M)
        desc = re.search(r'^description:\s*(.+)$', front, re.M)
        if not name or name.group(1).strip('"\'') != entry:
            problems.append(f'{entry}: name does not match the directory')
        if not desc or len(desc.group(1).strip('"\'')) < 30:
            problems.append(f'{entry}: description missing or too short')
    return not problems, f'{count} skills', problems


def check_patch_series(verbose=False):
    """R08: the numbers and hunk headers of the patch series hold."""
    script = os.path.join(REPO, 'tools', 'validate-repo.py')
    if not os.path.isfile(script):
        return False, 'validate-repo.py missing', [script]
    res = subprocess.run([sys.executable, script], cwd=REPO,
                         capture_output=True, text=True, encoding='utf-8',
                         errors='replace')
    if res.returncode != 0:
        tail = [l for l in (res.stdout + res.stderr).splitlines()
                if l.strip()][-6:]
        return False, 'validate-repo.py failed', tail
    return True, 'patch series and script syntax', []


def check_tests(verbose=False):
    """R09: the first-party tests under tools/tests pass."""
    files = sorted(glob.glob(os.path.join(REPO, 'tools', 'tests',
                                          'test_*.py')))
    if not files:
        return False, 'no tests found', ['tools/tests/test_*.py']
    problems = []
    for path in files:
        res = subprocess.run([sys.executable, path], cwd=REPO,
                             capture_output=True, text=True, encoding='utf-8',
                             errors='replace')
        if res.returncode != 0:
            rel = os.path.relpath(path, REPO)
            problems.append(f'{rel}: failed')
            tail = [line for line in (res.stdout + res.stderr).splitlines()
                    if line.strip()][-6:]
            problems.extend(tail)
    return not problems, f'{len(files)} files', problems


CHECKS = {
    'R01': ('doc links resolve', check_doc_links),
    'R03': ('LF line endings', check_line_endings),
    'R04': ('no device captures in git', check_captures),
    'R05': ('no credentials in tracked files', check_secrets),
    'R06': ('boards.py == shim/board.h', check_board_sync),
    'R07': ('skill front matter', check_skills),
    'R08': ('patch series and tool syntax', check_patch_series),
    'R09': ('first-party tests pass', check_tests),
}


def declared_in_agents():
    text = read('AGENTS.md')
    return set(re.findall(r'^\|\s*(R\d{2})\s*\|', text, re.M))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--only', action='append', default=[],
                    help='run one check, repeatable')
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()

    if args.list:
        for rid, (what, _) in sorted(CHECKS.items()):
            print(f'{rid}  {what}')
        return 0

    declared = declared_in_agents()
    problems_seen = 0
    covered = set()
    for rid in sorted(declared - set(CHECKS)):
        print(f'[-] {rid} is declared in AGENTS.md but has no check here')
        problems_seen += 1
    for rid in sorted(set(CHECKS) - declared):
        print(f'[-] {rid} exists here but AGENTS.md does not declare it')
        problems_seen += 1

    for rid, (what, fn) in sorted(CHECKS.items()):
        if args.only and rid not in args.only:
            continue
        ok, summary, problems = fn(args.verbose)
        mark = 'OK  ' if ok else 'FAIL'
        print(f'[{mark}] {rid} {what:<38} {summary}')
        if not ok:
            for p in problems[:12]:
                print(f'         - {p}')
            if len(problems) > 12:
                print(f'         - ... {len(problems) - 12} more')
            problems_seen += 1
        covered.add(rid)

    if args.only:
        missing = set(args.only) - set(CHECKS)
        for rid in sorted(missing):
            print(f'[-] unknown check {rid}')
            problems_seen += 1

    if problems_seen:
        print(f'\ncheck-agent: {problems_seen} problem(s)')
        return 1
    print('\ncheck-agent: every check passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
