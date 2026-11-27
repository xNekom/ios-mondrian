# MondrianAudio.driver

The CoreAudio HAL plug-in that gives iOS the phone's speaker (and, once the
kernel nodes exist, the Actuator for haptics and the Codec for the microphone).

`MondrianAudio.driver` is a flat bundle: `Info.plist` and the executable named
by `CFBundleExecutable`. `tools/build-mondrian-hal.sh` builds it with the WSL
clang and ld64.lld, and `tools/wsl/install-mondrian-hal.sh` installs it over
USB into `/System/Library/Audio/Plug-Ins/HAL/` and restarts `mediaserverd`.

## Why this design

Above the HAL sits `VirtualAudio.plugin`, which routes everything iOS plays. It
knows an iPhone's devices by the **UID strings** and builds the speaker route
only when these exist:

| UID | What it is here |
| --- | --- |
| `Speaker` | stereo output to `/dev/mondrian-audio` + the silent stereo input the amplifiers read on an iPhone |
| `Hawking` | one silent input, the mandatory companion; **without it everything stays on `Null_Device`** |
| `Actuator` | mono output to `/dev/mondrian-haptic` (the motor, iOS haptics as waveforms) |
| `Codec` | mono input from `/dev/mondrian-mic` (built-in microphone, not implemented yet) |

A plug-in with only one device, or with a UID like `MondrianSpeaker_UID`, loads
and still routes nothing. That trap is measured on three working ports
(ios-redfin, pixel3-ios, ios-guacamole) and is why the UID here is `Speaker`.

iOS sets the speaker's volume control once, to 0 dB, and keeps the iPhone X's
speaker in software volume mode, so samples arrive already scaled: the kernel
adds no extra gain of its own.

## Where it comes from

The object model, the property table, the system clock (`REDWOOD_AUDIO_RATE`
frames per second of `mach_absolute_time()`), the frame ring and its writer
thread are HackiOS's plug-in (MIT, `LICENSE.hakios`), taken from
`akshaynexus/iOSPlus10` `userland/audio/NegroniAudio.c`, itself from
`oosexgang/hackios-xnu-userland` and `ios-apollo`. Only the names, the device
paths and the ioctl letters are ours.

`mondrian_asp.h` is the AudioServerPlugIn interface (`AudioHardwareBase.h` is
macOS-only and the iPhoneOS SDK has no header); `mondrian_audio.h` and
`mondrian_haptic.h` are the user/kernel ABI, mirrored in the kernel source.

## Build

    bash tools/build-mondrian-hal.sh /root/mondrian-hal/MondrianAudio.driver

The writer thread, not the HAL real-time thread, opens the node; without the
kernel side every write fails with `ENODEV`, which the plug-in counts and
drops, so the bundle is harmless to install before the node exists.
