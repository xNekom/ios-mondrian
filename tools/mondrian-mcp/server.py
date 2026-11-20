#!/usr/bin/env python3
"""Read-only MCP bridge for the mondrian console ring.

These tools never flash, reboot or inject input. They read the live ring, the
previous boot's ring, the panel and the kernel banner; `tools/wsl/attach.sh`
attaches the phone to WSL first, the same way every other script in the repo
does.

`prove_kernel` is the point. A RAM boot that dies falls back to `boot_b` and
answers with the previous kernel; every command then "does not exist" and the
answer is not about the image that was just built. Compare the two banners
before trusting anything else.
"""
from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

from mcp.server.fastmcp import FastMCP

REPO = Path(__file__).resolve().parents[2]
KERNEL = Path(os.environ.get("MONDRIAN_KERNEL", str(REPO / "xnu/out/kernel.development.mondrian")))
RING = REPO / "out/mcp-ring.txt"
PREV = REPO / "out/mcp-prev.txt"
PANEL = REPO / "out/mcp-panel.png"
WSL = os.environ.get("WSL_EXE", r"C:\Windows\System32\wsl.exe")
BANNER = re.compile(rb"Darwin Kernel Version[^\x00;]*")
MAX_LINES = 2000
MAX_LINE = 4000

mcp = FastMCP("mondrian-device")


def _wsl_path(path: Path) -> str:
    drive, rest = os.path.splitdrive(str(path))
    if drive:
        return "/mnt/" + drive[0].lower() + rest.replace("\\", "/")
    return str(path).replace("\\", "/")


def _rel(path: Path) -> str:
    """A repo-relative path as WSL sees it: forward slashes, never a backslash."""
    return path.relative_to(REPO).as_posix()


def _run(cmd: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=REPO)


def _wsl(script: str, timeout: int) -> str:
    proc = _run([WSL, "-e", "bash", "-lc", script], timeout)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(detail or f"wsl exited {proc.returncode}")
    return proc.stdout


def _attach(timeout: int = 60) -> None:
    _wsl(f"cd {shlex.quote(_wsl_path(REPO))} && bash tools/wsl/attach.sh", timeout)


def _ring(command: str, args: list[str], timeout: int) -> None:
    (REPO / "out").mkdir(exist_ok=True)
    _attach()
    line = " ".join(shlex.quote(part) for part in ["python3", "tools/usb-ring.py", command, *args])
    _wsl(f"cd {shlex.quote(_wsl_path(REPO))} && {line}", timeout)


def _tail(path: Path, max_lines: int) -> str:
    if not path.is_file():
        raise RuntimeError(f"{path} was not written")
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return "\n".join(line[:MAX_LINE] for line in lines[-max_lines:])


def _banner(data: bytes) -> str:
    matches = BANNER.findall(data)
    return matches[-1].decode("utf-8", "replace").strip() if matches else ""


@mcp.tool()
def ring_dump(max_lines: int = 300) -> str:
    """Read the live console ring (read-only; attaches the phone to WSL first)."""
    max_lines = max(1, min(max_lines, MAX_LINES))
    _ring("dump", [_rel(RING)], 120)
    return _tail(RING, max_lines)


@mcp.tool()
def ring_prev(max_lines: int = 2000) -> str:
    """Read the previous boot's ring from userdata (kernel 0329)."""
    max_lines = max(1, min(max_lines, MAX_LINES))
    _ring("prev", [_rel(PREV)], 180)
    return _tail(PREV, max_lines)


@mcp.tool()
def prove_kernel() -> str:
    """Compare the live ring's Darwin banner with the kernel on disk."""
    _ring("dump", [_rel(RING)], 120)
    got = _banner(RING.read_bytes())
    if not KERNEL.is_file():
        return f"ring: {got or '(no banner)'}\nkernel: missing {KERNEL}\nverdict: unknown"
    want = _banner(KERNEL.read_bytes())
    verdict = "match" if got and got == want else "MISMATCH"
    return f"ring: {got or '(no banner)'}\nkernel: {want or '(no banner)'}\nverdict: {verdict}"


@mcp.tool()
def ring_status() -> str:
    """Read the ring's absolute position; shows whether it is still growing."""
    _attach()
    return _wsl(f"cd {shlex.quote(_wsl_path(REPO))} && python3 tools/usb-ring.py pos", 30)


@mcp.tool()
def panel_capture() -> str:
    """Capture the panel at half scale to out/mcp-panel.png and return its path."""
    _ring("screen", [_rel(PANEL)], 90)
    return str(PANEL)


@mcp.tool()
def decode_log(path: str) -> str:
    """Decode a raw mondrian-log.raw dump (header + 4 MiB ring) to text."""
    raw = Path(path)
    if not raw.is_file():
        raise RuntimeError(f"{path} does not exist")
    proc = _run([sys.executable, str(REPO / "tools/decode-mondrian-log.py"), str(raw)], 120)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(detail or f"decoder exited {proc.returncode}")
    return proc.stdout[-200000:]


if __name__ == "__main__":
    mcp.run()
