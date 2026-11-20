#!/usr/bin/env python3
"""Tests for tools/verify-image.py -- no phone, no boot.

Why these cases: the verifier exists for the silent failure, not the loud one.
A failed build is obvious; a stale shim-boot.img is not, and the phone boots
the previous kernel while the new command looks absent.  So every case below
builds a synthetic image and then breaks exactly one thing.

Run: python3 tools/tests/test_verify_image.py
"""
from __future__ import annotations

import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verify = load('verify_image', REPO / 'tools' / 'verify-image.py')


def payload_bytes(cmdline: str) -> bytes:
    out = bytearray(0x448 + 64)
    out[0:8] = b'MONDRIAN'
    struct.pack_into('<II', out, 8, 1, 1)
    data = cmdline.encode()
    out[verify.CMDLINE_OFF:verify.CMDLINE_OFF + len(data)] = data
    return bytes(out)


def lz4p(payload: bytes, compressed: bytes | None = None,
         declared: int | None = None) -> bytes:
    data = compressed if compressed is not None else b'FAKE-LZ4' * 64
    size = declared if declared is not None else len(data)
    return b'LZ4P' + struct.pack('<IQQ', 1, len(payload), size) + data


def boot_image(kernel_section: bytes, page: int = 4096) -> bytes:
    header = bytearray(page)
    header[0:8] = b'ANDROID!'
    struct.pack_into('<I', header, 8, len(kernel_section))
    struct.pack_into('<I', header, 36, page)
    return bytes(header) + kernel_section + b'\x00' * page


class Capture:
    """One build directory: image, payload, blob, kernel and manifest."""

    def __init__(self, root: Path, cmdline: str = 'debug=0xc usb=2',
                 blob: bytes | None = None, section_prefix: bytes = b'\x00' * 112):
        self.root = root
        self.paths = {
            'image': root / 'shim-boot.img',
            'payload': root / 'payload.bin',
            'blob': root / 'payload.lz4p',
            'kernel': root / 'kernel.development.mondrian',
            'manifest': root / 'image-manifest.json',
        }
        self.cmdline = cmdline
        self.paths['payload'].write_bytes(payload_bytes(cmdline))
        self.paths['kernel'].write_bytes(b'\x00' * 64 + b'Darwin Kernel Version 22.6.0;')
        blob = blob if blob is not None else lz4p(self.paths['payload'].read_bytes())
        self.paths['blob'].write_bytes(blob)
        self.paths['image'].write_bytes(boot_image(section_prefix + blob))


class RoundTrip(unittest.TestCase):
    def test_record_then_verify(self):
        with tempfile.TemporaryDirectory() as raw:
            cap = Capture(Path(raw))
            manifest = verify.record(cap.paths)
            self.assertEqual(manifest['cmdline'], cap.cmdline)
            problems, _ = verify.verify(cap.paths, [])
            self.assertEqual(problems, [])

    def test_expect_args_present(self):
        with tempfile.TemporaryDirectory() as raw:
            cap = Capture(Path(raw), 'debug=0xc usb=2 thermalthr=30')
            verify.record(cap.paths)
            problems, _ = verify.verify(cap.paths, ['thermalthr=30'])
            self.assertEqual(problems, [])

    def test_expect_args_missing(self):
        with tempfile.TemporaryDirectory() as raw:
            cap = Capture(Path(raw))
            verify.record(cap.paths)
            problems, _ = verify.verify(cap.paths, ['thermalthr=30'])
            self.assertTrue(any('thermalthr=30' in p for p in problems), problems)


class Refusals(unittest.TestCase):
    def test_rebuilt_image_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            cap = Capture(Path(raw))
            verify.record(cap.paths)
            cap.paths['image'].write_bytes(
                cap.paths['image'].read_bytes() + b'X')
            problems, _ = verify.verify(cap.paths, [])
            self.assertTrue(any('sha256' in p for p in problems), problems)

    def test_tampered_payload_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            cap = Capture(Path(raw))
            verify.record(cap.paths)
            data = bytearray(cap.paths['payload'].read_bytes())
            data[verify.CMDLINE_OFF] ^= 0x01
            cap.paths['payload'].write_bytes(bytes(data))
            problems, _ = verify.verify(cap.paths, [])
            self.assertTrue(any('payload.bin sha256' in p for p in problems),
                            problems)

    def test_missing_manifest_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            cap = Capture(Path(raw))
            with self.assertRaises(verify.Refused):
                verify.verify(cap.paths, [])

    def test_long_cmdline_is_refused_at_record(self):
        with tempfile.TemporaryDirectory() as raw:
            cap = Capture(Path(raw), 'x' * (verify.USERLAND_BOOTARGS + 1))
            with self.assertRaises(verify.Refused):
                verify.record(cap.paths)

    def test_truncated_blob_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            payload = payload_bytes('debug=0xc usb=2')
            blob = lz4p(payload, compressed=b'0123456789', declared=100)
            cap = Capture(Path(raw), blob=blob)
            verify.record(cap.paths)
            with self.assertRaises(verify.Refused):
                verify.verify(cap.paths, [])

    def test_bad_image_magic_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            cap = Capture(Path(raw))
            cap.paths['image'].write_bytes(b'\x00' * 4096)
            verify.record(cap.paths)
            with self.assertRaises(verify.Refused):
                verify.verify(cap.paths, [])


class Constants(unittest.TestCase):
    def test_the_packer_and_the_verifier_agree(self):
        mkpayload = load('mkpayload_constants', REPO / 'tools' / 'mkpayload.py')
        self.assertEqual(verify.CMDLINE_OFF, mkpayload.CMDLINE)
        self.assertEqual(verify.BOOT_LINE_LENGTH, mkpayload.BOOT_LINE_LENGTH)
        self.assertEqual(verify.USERLAND_BOOTARGS, mkpayload.USERLAND_BOOTARGS)


if __name__ == '__main__':
    unittest.main(verbosity=2)
