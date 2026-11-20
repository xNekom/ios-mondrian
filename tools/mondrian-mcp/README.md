# mondrian-device MCP

A read-only MCP bridge for the console ring. It runs `tools/usb-ring.py` over
WSL, after `tools/wsl/attach.sh`, and returns the tail instead of the whole
4 MiB ring.

| Tool | What it reads |
| --- | --- |
| `ring_dump(max_lines)` | the live ring |
| `ring_prev(max_lines)` | the previous boot's ring (`0329`) |
| `prove_kernel()` | the ring and `xnu/out/kernel.development.mondrian` banners |
| `ring_status()` | the ring's absolute position |
| `panel_capture()` | a half-scale PNG of the panel, `out/mcp-panel.png` |
| `decode_log(path)` | a raw `mondrian-log.raw` from recovery |

The phone must be booted with `usb=2` (or be in fastboot, where the ring is
not live). `attach.sh` fails with a named reason when no `1209:0001` or
`18d1:d00d` device is enumerable.

## Install

```powershell
$venv = "$env:LOCALAPPDATA\opencode-mcp\mondrian-device\.venv"
python -m venv $venv
& "$venv\Scripts\python.exe" -m pip install -r tools\mondrian-mcp\requirements.txt
```

Global OpenCode config, under `mcp.servers`:

```jsonc
"mondrian-device": {
  "type": "local",
  "command": [
    "C:\\Users\\Pedro\\AppData\\Local\\opencode-mcp\\mondrian-device\\.venv\\Scripts\\python.exe",
    "C:\\Users\\Pedro\\Documents\\GitHub\\ios-mondrian\\tools\\mondrian-mcp\\server.py"
  ],
  "cwd": "C:\\Users\\Pedro\\Documents\\GitHub\\ios-mondrian",
  "timeout": { "startup": 60000, "execution": 180000 }
}
```

## Why read-only

`usb-ring.py` can also reboot, power off, inject taps and write PMIC
registers. Those are deliberately absent here: an agent that can flash or
reboot on its own is a different risk class from one that can read a log. Use
the shell for a deliberate write, with the same confirmation the repo already
requires.

## Test

```powershell
& "$venv\Scripts\python.exe" -m unittest tools\mondrian-mcp\test_server.py -v
```
