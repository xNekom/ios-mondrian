#!/usr/bin/env python3
"""Unit tests for the pure parts of the mondrian-device MCP server."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("mondrian_device_server", HERE / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class BannerTest(unittest.TestCase):
    def test_takes_the_last_match(self):
        data = (
            b"old Darwin Kernel Version 22.6.0: root:xnu-8796.1~1/RELEASE_ARM64_T6020;"
            b" new Darwin Kernel Version 22.6.0: root:xnu-8796.141.3~1/RELEASE_ARM64_T6020;"
        )
        self.assertEqual(
            server._banner(data),
            "Darwin Kernel Version 22.6.0: root:xnu-8796.141.3~1/RELEASE_ARM64_T6020",
        )

    def test_missing_banner_is_empty(self):
        self.assertEqual(server._banner(b"no banner here"), "")

    def test_works_on_a_kernel_binary(self):
        with tempfile.NamedTemporaryFile(delete=False) as fh:
            fh.write(b"\x00\x01Darwin Kernel Version 22.6.0: root:xnu-test;")
            name = fh.name
        try:
            self.assertEqual(server._banner(Path(name).read_bytes()), "Darwin Kernel Version 22.6.0: root:xnu-test")
        finally:
            Path(name).unlink()


class TailTest(unittest.TestCase):
    def test_keeps_the_last_lines(self):
        with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as fh:
            fh.write("a\nb\nc\n")
            name = fh.name
        try:
            self.assertEqual(server._tail(Path(name), 2), "b\nc")
        finally:
            Path(name).unlink()

    def test_caps_the_line_length(self):
        with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as fh:
            fh.write("x" * (server.MAX_LINE + 10) + "\n")
            name = fh.name
        try:
            self.assertEqual(len(server._tail(Path(name), 1)), server.MAX_LINE)
        finally:
            Path(name).unlink()


class WslPathTest(unittest.TestCase):
    def test_maps_a_drive(self):
        self.assertEqual(server._wsl_path(Path(r"C:\Users\Pedro\ios-mondrian")), "/mnt/c/Users/Pedro/ios-mondrian")

    def test_keeps_a_posix_path(self):
        self.assertEqual(server._wsl_path(Path("/mnt/c/ios-mondrian")), "/mnt/c/ios-mondrian")

    def test_repo_relative_path_uses_forward_slashes(self):
        self.assertEqual(server._rel(server.RING), "out/mcp-ring.txt")


if __name__ == "__main__":
    unittest.main()
