#!/usr/bin/env python3
"""Tests for the board command lines in tools/boards.py.

Why these cases: the command line is the only channel into the kernel and it
has a hard ceiling.  608 bytes makes `kern.bootargs` unreadable for every iOS
process, watchdogd aborts and launchd respawns it; `usb=2` is the only way the
ring and the control channel exist at all.  Both failures look like a kernel
bug, so they are checked here before a build.

Run: python3 tools/tests/test_boards_cmdline.py
"""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


boards = load('boards_cmdline', REPO / 'tools' / 'boards.py')
LIMIT = 607


class CommandLine(unittest.TestCase):
    def test_every_board_fits_the_reader(self):
        for name, board in boards.BOARDS.items():
            with self.subTest(board=name):
                self.assertLessEqual(len(board.cmdline.encode()), LIMIT,
                                     f'{name}: {len(board.cmdline.encode())} bytes')

    def test_mondrian_keeps_the_usb_channel(self):
        board = boards.BOARDS['mondrian']
        self.assertIn('usb=2', board.cmdline.split())

    def test_mondrian_keeps_debug_output(self):
        tokens = boards.BOARDS['mondrian'].cmdline.split()
        self.assertTrue(any(token.startswith('debug=') for token in tokens))

    def test_no_padding_or_empty_tokens(self):
        for name, board in boards.BOARDS.items():
            with self.subTest(board=name):
                self.assertEqual(board.cmdline, board.cmdline.strip())
                self.assertNotIn('  ', board.cmdline)
                self.assertNotIn('\t', board.cmdline)
                self.assertTrue(all(token for token in board.cmdline.split()))

    def test_mondrian_payload_magic_is_the_one_the_shim_expects(self):
        self.assertEqual(boards.BOARDS['mondrian'].payload_magic, b'MONDRIAN')


if __name__ == '__main__':
    unittest.main(verbosity=2)
