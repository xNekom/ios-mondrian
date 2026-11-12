---
name: xnu-fb-console-triage
description: Read a photo of the mondrian framebuffer console after an XNU boot and decide what happened (hang, timeout, panic, or progress), including the colour-bar self-test. Use whenever the user attaches a boot photo, a screen transcript, or asks "what does this boot say / where did it stop".
---

# Triage a boot photo

The only output channel the mondrian kernel has right now is the framebuffer
left by the ABL (`cont_splash_region`, 1440x3200). There is no serial, no USB,
no persistent log. Every diagnosis starts by reading a photograph, so read it
carefully and in the same order every time.

## 1. Read the image

1. The photo is usually rotated 90 or 270 degrees. Rotate before reading:
   `sips -r 90 IMG.jpg --out /tmp/b.txt` (or `-r -90`).
2. Crop to the text block, the console is only the upper part of the panel.
3. `read` the resulting file directly so the image reaches you, do not try to
   OCR it with a tool first.
4. If it is a screenshot instead of a photo, rotate nothing.

Font quirks that produce wrong readings, all seen in this project:

| glyph | can be read as | consequence |
|-------|----------------|-------------|
| `8`   | `B`            | `0x1b` never; but `0x8` becomes `0xB` |
| `0`   | `O`            | `0x10f` vs `0x1Of` |
| `6`   | `b`            | `0x36` vs `0x3b` |
| `4`   | `A`            | `0x04` vs `0x0A` |
| `2`   | `Z`            | `0x02` vs `0x0Z` |

Ambiguous digits in a hex value mean the value is *unconfirmed*. Ask for a
second photo of the same boot only when the ambiguous value is the decision
point; otherwise say which value is uncertain in your report.

## 2. The screen is a ring, not a page

The console wraps by reusing the top row (`0092`), so the text below the
cursor marker is the older part of one screenful and the text above it is the
newest. Find the cursor block (a dark blue cell): the line above it is the
last line written, and the reading order runs down from it and continues at
the top. The screen therefore always holds the *last* screenful, in two
pieces.

Before `0092` the console cleared the whole area on every wrap, which is also
why a boot that ends in a full screen can hide several seconds of log: the
screen you see is the newest, and the top row is the oldest. If the top line
is not the start of a known boot banner (`MONDRIAN ...`, `pmap ...`), the log
is longer than the screen and everything before the oldest visible line is
gone.

## 3. Classify the last line

| last line | meaning |
|-----------|---------|
| a `x sent, waiting` / `waiting for` line | the code is inside a wait. If the wait is spin-counted the boot continues eventually; if it is clock-based and the clock is frozen it hangs forever |
| `never completed: hcs ... is ... dbr ...` | the host never finished the request: read the UTRD dump, do not retry blindly |
| `timed out` / `timeout` | the wait expired and the code took its error path; look at the line *after* it |
| `panic` / register dump / `Debugger` | panic; capture every register line, they are needed |
| the colour-bar self-test rows | the framebuffer write path works; the boot reached `pe_serial` paint time |
| a `device_add_rd0` / `IOFindBSDRoot` line | the kernel is in BSD root mount, i.e. storage is the blocker |

A screen that ends in the *middle* of an expected sequence with the sequence's
next line absent is a hang, not an error path. A screen that ends after an
explicit error message is a handled failure; the interesting question is then
why the caller continued or stopped.

## 4. Compare against the expected sequence

Read the driver that produces the lines before guessing. For UFS the sequence
is in `bsd/dev/mondrian_ufs.c` (or the current patch):
`hce/hcs/cap/ver` -> `NOP OUT sent/received` -> `query ... sent` + value ->
`before any wake: TUR n, power 0x.., fDeviceInit 0x..` -> `START STOP ACTIVE
on LUN 0x..: n` -> `LUN n answered after the wake on 0x..` -> GPT/partition
lines -> `device_add_rd0`.

Report as: proven (what the lines establish), inferred (what follows from
them), unknown (what the screen cannot tell). Never present an inference as a
reading.

## 5. Panics

`tools/ios-crash.py` decodes XNU panic text when a full dump exists. From a
photo, transcribe the `panic(cpu N caller 0x...):` line, the `Debugger
message:`, and the `@source/file.c:line` frames in order. The `caller`
address is only useful with the matching kernel, so name the CI artifact or
commit the kernel came from.

## 6. Housekeeping

- Boot photos, serial numbers and device dumps stay out of git. Keep working
  copies in `/private/tmp` or `~/Downloads`.
- Record what the photo proved in the mondrian handoff of `NOTES.md` before
  stopping, with the run id of the kernel that produced it.
