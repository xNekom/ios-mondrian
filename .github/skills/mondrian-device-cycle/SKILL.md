---
name: mondrian-device-cycle
description: Drive one mondrian experiment from the host — build, RAM boot, prove which kernel answered, recover the slot after a failed boot, attach the phone to WSL. Use when a boot refuses to start, when the ring answers with an old banner, when fastboot says "Failed to load/authenticate boot image", or before running any tools/wsl script.
---

# One experiment, one cycle

The loop is `tools/wsl/cycle.sh <cmd> "<args>"`: build the image, boot it from
RAM, compare the ring's banner with the kernel on disk, then run the ring
commands. A build is ~10-15 minutes and a boot ~2.5, so a second question in
the same boot is free and a repeated boot is not.

## A boot that refuses to start

After a boot that dies, ABL marks the active slot unbootable and then refuses
**every** `fastboot boot` with `Failed to load/authenticate boot image: Not
Found`. A 4 KB stub is refused the same way, and so is an image that booted an
hour earlier. This is not a broken image and not a kernel crash:

```sh
fastboot getvar current-slot          # never guess the slot
fastboot --set-active=<current-slot>  # clears the mark
```

`cycle.sh` does this before every boot. Without it the refusal reads as a
kernel that crashes, and the ring answering with the previous kernel's banner
"confirms" the wrong diagnosis.

On Windows the value arrives with a CR (`b\r`), and `--set-active=b\r` is
rejected with `Slot b does not exist` while the mark survives: every RAM boot
then dies the same way. Strip it (`| tr -d '\r'`) and check the command's exit
status instead of writing its output to a log nobody reads.

A RAM boot after an XNU run can also die at the shim handoff and fall back to
`boot_b`. Measured 2026-11-19: two attempts died, the third in the same session
booted the image, so retry (`ATTEMPTS=N`, which `cycle.sh` does) instead of
waiting for a power cycle that nobody is there to perform.

The retry has one trap of its own: `boot_b` **leaves fastboot**, so the next
attempt's `fastboot getvar` blocks for ever on `< waiting for any device >` and
the run looks like a boot that hung instead of a device that is simply not in
the bootloader any more. `cycle.sh` checks `fastboot devices` before each
attempt and asks the running kernel for fastboot again when it is gone; time
bound the `getvar` and `--set-active` too.

## When the ring goes silent

`pos` and `wfile` stop answering while ICMP on the same link still does: the
kernel is up and its ring thread is not. Draining udp/5141, re-attaching with
`usbipd`, and a detach/attach bus reset were all measured 2026-11-19 and none of
them brings it back; `fastboot devices` shows nothing because the gadget is
still the XNU one. There is no remote recovery: ask for a power cycle (10 s off,
power + volume down) and check nothing is left holding a pipe while you wait.

## Driving the UI with taps

`mondrianfb_blank=30` switches the panel off when nothing has been presented for
30 s, and **the first touch only wakes it**: that touch does not reach the app.
A tap that "does nothing" is usually this, not a wrong coordinate (measured
2026-11-19: the same dock tap opened Safari on one attempt and was swallowed on
the next). Send a throwaway tap at a harmless point, wait two seconds, then the
real one. `respring` plus `key 3` (home) puts the phone on a known screen between
attempts, and a `screen` capture costs about a minute when you need to be sure.

The upload is the expensive part of a round, not the taps: 22 MB over the
windowed `wfile` takes ten to fifteen minutes, so keep a dylib on the phone
across experiments and upload it once per boot rather than once per test.

## Prove the kernel before trusting any answer

A RAM boot that dies falls back to `boot_b`, so "command not found" means "old
kernel" as often as "bug". Compare the ring's `Darwin Kernel Version` line with
the kernel on disk before reading anything else the ring says.

A `grep -c "MONDRIAN HAP" kernel` written inline in PowerShell comes back 0
because the quotes never reach grep. Put the check in a script file.

## Attach the phone inside the script, every time

WSL shuts down between tool calls: `usbipd attach --wsl` and the `192.168.7.1`
address have to be redone inside each script or the first send fails with
`Errno 99`. Two silent failures hide there:

- the bus id moves with the port, so a stale `--busid` leaves the ring dead
  while `fastboot devices` (host side, no `usbipd`) keeps answering. Look it up
  by USB id: `usbipd list | grep -E '1209:0001|18d1:d00d'`.
- `attach` returns before `cdc_ether` creates the netdev, so wait for the
  interface instead of sleeping. Never trust the hardcoded `enx…` default.

## Never pipe a build or a flash

`bash mkimg.sh | head -1` dies of SIGPIPE and leaves the previous image: the
phone boots the old kernel and the new command "does not exist".
`bash tools/flash-root.sh IMG | tail -6` throws away the `fastboot flash`
progress and its failure, so a flash that never started looks like one that
finished and the image gets blamed. Log to a file and read the exit status.

The same goes for editing a script that is still running: bash reads it as it
goes, so a mid-run edit corrupts the next line it parses and the run lies about
why it failed.

## Deploy from Windows

`git push` inside WSL stops at `could not read Username for
'https://github.com'` (no credential helper). Push from PowerShell; CI only
sees what is in `origin/mondrian`, so push before dispatching a run.

`tools/flash-root.sh` still asks before every write, and every destructive step
waits for the user. Fastboot access is the real disaster baseline: a reachable
fastboot restores the phone, a cooked firmware image bricks it.
