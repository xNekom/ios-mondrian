# Bluetooth: the shared state

Two agents work this tree at once: one on the UI and GPU, one on Bluetooth.
This file is the handoff between them. It holds only what the next hand needs:
who is on the phone, what the last boot proved, and the questions that need the
user. The hardware, the UART and what iOS expects are in
`docs/MONDIAN_WIRELESS.md`; the work list is `docs/MONDIAN_PORT.md`.

## Claiming the phone

The phone takes one boot at a time: a RAM boot replaces whatever the other
agent is running, and a failed boot marks the slot unbootable until
`fastboot --set-active` clears it (`tools/wsl/cycle.sh` does that itself).
Before building or booting, read the `Owner` line below; write it when the
boot starts and clear it when the ring has answered. A boot that changes the
kernel changes it for the other agent too, so say which patch is in the image.

Owner: UI (2026-11-23, patch 0405 in the image, 396 patches apply)
Last proven boot: `Darwin Kernel Version 22.6.0: Sun Nov 22 19:01:48 CET 2026`
with 0405 in the image, booted from RAM on 2026-11-23 and reached the home
screen.

## What the UI side needs from the Bluetooth side

Nothing blocks the UI. The picture bridge and the launch fix load in every
app, so a new app that draws a switch or a picture is worth a line here when
it behaves differently.

## What the Bluetooth side needs from the UI side

The UI side has not touched `tools/mondrian-bt*`, `tools/bt-*` or
`bsd/dev/mondrian_bt*` and will not without a note here first.

## Measured 2026-11-23, from the UI side

- The Bluetooth pane still draws the switch on (green, with its knob) and
  `DEVICES` spins with no device listed; the Settings root's Airplane switch
  draws off, so a switch that does not draw is no longer a UI-side symptom.
- The app switcher's cards now show each app's own picture, including the
  Bluetooth pane as it was left.

## Measured 2026-11-22, from the UI side

- The Bluetooth pane draws: the switch is on (green, with its knob), the page
  reads "discoverable as iPhone" and `DEVICES` spins with no device listed, so
  nothing is paired at that moment. A capture is `out/bt-pane.png`.
- The BCM UART is transmitting: the ring repeats `btuart: tx 1 bytes done 1`
  and `m_cmd0 ... status 0x41041`, so the controller answers commands.
- No audio route exists. `MONDRIAN TONE: play 0 duration 1.00 route` comes back
  with an empty route, which is why A2DP and Alexa cannot be end-to-end: there
  is no output device for iOS to render into.
- `mondrian-bt-keys` holds the PC key only; the Echo's key is not there and the
  ring has no real `evt 18`, so a re-pair is needed before a link can be read.

## Questions only the user can answer

1. Which audio output should the port expose: a virtual `AudioServerPlugIn`
   (Jesvi's `userland/src/audio_plugin.c` is the reference) or a codec driver?
   Nothing about A2DP can be finished before this is chosen.
2. The Echo re-pair: forget it in iOS, put it in pairing mode, and say when.
