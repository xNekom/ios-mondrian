# Reference-port findings (2026-11-27)

What other iOS-on-Qualcomm ports have published about the subsystems we still need.
Use this as the first stop before re-deriving a trap; each entry names the repo
and the concrete mechanism, not just a status.

## Audio routing — `Lakr233/vphone-cli`, `Research/Guest/virtio_sound.html`

A HAL device is only routed by VirtualAudio when its UID is one VirtualAudio's
device factory knows. `Speaker` is `Unhandled UID`; **`PuffinOutput`** publishes
the `pspk` speaker port and becomes `master` of the default VAD (`vdef`), which
is what makes CoreAudio bind our stream. The same page documents the remaining
gates: a `ProductIDOverride` in `com.apple.audio.virtualaudio` (not present in
our iOS 16.7 build), the speaker-protection throws, a mute-set throw, and the
I/O-block lifecycle (AudioServerDriver clears blocks at every stop, so they must
be reinstalled before each start).

`Research/Guest/virtualaudio_speaker_route_throws.html` patches six throw sites
plus the mute-set throw in VirtualAudio so a non-codec speaker cannot abort
`mediaserverd`. The patches are found by string anchors and code shape, not by
offset, so they could be re-derived for iOS 16.7. Our crash is the same class of
failure: a device manager without a bundle id reaches `objc_msgSend` with NULL
in `HALS_System::DeviceManagerCreated` (REA/Rizin confirmed).

Applied here: our HAL now publishes `PuffinOutput`. `VirtualAudio` still
crashes on this port, so routing without it is unresolved.

Tried 2026-11-27: REA/Rizin located the six fatal sites in our iOS 16.7
`VirtualAudio` (2x `bl std::terminate` after a fault log at 0xdac0c/0x18ac64;
4x `__cxa_throw` for `Precondition failure.`, `Unexpected HAL speaker
protection` and `No default VAD present` at 0x18a21c/0x18a370/0x18ad70/
0x18ae40). A reproducible patcher (`out/patch-virtualaudio.py`) branches each
to its function epilogue; the patched bytes were verified on the device. The
crash did **not** change: it stays at `CoreFoundation+0x7ab64` in
`HALS_System::DeviceManagerCreated` (a NULL C-string reaching
`stringWithUTF8String:`), which is a different path from vphone's walker
throws. Do not re-run the VirtualAudio patch as the fix for our crash; the
next front is the NULL bundle-id in CoreAudio's device manager. Also note the
bundle must be re-sealed after patching (`sealGuestBundle`) when AMFI is not
permissive, and copying 6.6 MB with `wfile` damages the HFS volume.

## Haptics — `jebbranch/ios-port-marble`, `docs/haptics-abi-2026-10-30.md`

Kernel Callan/PM8350B haptics work, but UI haptics never reach the kernel:
`AppleHapticsSupport::newUserClient` is never called. The decision is made in
userland: `ButtonResolver.framework` builds `GlobalForceFeel`/`GlobalConfig`,
and `BKSButtonHapticsController` loads haptics as **audio assets**
(`/Library/Audio/Tunings/D22/**/*.wav`, 18 ButtonHaptics groups) through
`AppleSPUHapticsAudioDriver`, not through IOKit. `GlobalForceFeel=1` means the
userland side considers haptics enabled; the missing piece is the per-button
definition/asset lookup. Our `Actuator` audio device is the right kernel sink;
we need the ButtonResolver asset path, not more SPMI work.

`akshaynexus/OneiOS` hosted 0086: CoreHaptics plays through the Actuator with a
DSP chain; ringtone vibration is a separate system-sound path that still does
not vibrate.

## Metal — `UniXNU/AdrenoMetal`, `bangprovn/ios-fuxi` `docs-lanes/metal-m9b.md`

A working system compositor uses `AdrenoMetal` (metal2vulkan + Turnip) with a
`NativeAdrenoMetal` plugin published through `MTLAddDevice`; backboardd and
SpringBoard must be admitted by name. The frontend lives in
`NativeAdrenoMetalPlugin.mm` / `NativeBridgeMetalFrontend.mm`; precompiled
shader caches and process-local Vulkan caches matter for first-frame latency.
`ios-fuxi` explicitly does **not** enable system CA Metal yet; it keeps a
deny-by-default process allowlist. Our kernel already has the Adreno 740 path;
the missing piece is the CoreAnimation-facing frontend and compositor
admission, not the GPU driver.

`Jesvi-iOS` (credited by OneiOS-A56) is a Metal-on-Mesa-Gallium AIR frontend for
iOS 16.5 and is the closest iOS 16 reference.

## Video / HEVC — `DenialOfGravity/ios-redfin`

Hardware video decode/encode is listed as not working on an otherwise mature
iOS 16 port. `ios-redfin`'s `phone/video/venus_core.c` + `vtvenc.c` + `venusd.c`
are the native a6xx path and the donor to copy before writing power or HFI code.
Expect a long bring-up; no reference port has VideoToolbox HEVC working on
iOS 16 with an Adreno.

## Wi-Fi — `DenialOfGravity/ios-redfin`, `bangprovn/ios-fuxi`

`ios-redfin`: Wi-Fi is driven from userland (`wland`) with an `Apple80211`
bridge; `Settings -> Wi-Fi`, join and rejoin work. `ios-fuxi`: `fuxi_wlan.c`
brings up WCN7850 and the iOS side is `fuxi-wifi-ios` (Apple80211 ioctl/station
bridge, property-only WLAN discovery, network-stack stand-in, WPA2 arithmetic).
The reusable piece for us is the iOS-side bridge, not the chip-specific power
sequence: our `mondrianbt=1` already supplies a transport token to bluetoothd.

## The audio crash on mondrian — conclusive controls (2026-11-27)

Three controls with the same kernel, root and ADT:

| Setup | mediaserverd crashes | node opened |
| --- | --- | --- |
| VirtualAudio only, our HAL absent | **0** | 0 |
| our HAL only, VirtualAudio absent | 0 | 1 |
| VirtualAudio + our HAL (any UID, any BundleID/ResourceBundle value) | **20-32** | 5-8 |
| VirtualAudio + **HackiOS donor HAL** (no factory export) | 0 | 0 |
| VirtualAudio + HackiOS donor HAL with `MondrianAudio_Create` exported | **20** | 5 |

So the crash is not the UID, not BundleID/ResourceBundle, not the `open()` of
the cdev (deferring it to StartIO changed nothing), not the Bluetooth plugin,
not `/product/audio`: it is `HALS_System::DeviceManagerCreated` registering a
device manager for a HAL plug-in while VirtualAudio is live. REA/Rizin put the
fault at `CoreFoundation+0x7ab64` with `x0 = 0` (a CFString/NULL C-string from
the manager's `+0x30` bundle-id). vphone only sees this class of failure in
its own walker throws, which we patched (6 sites) without effect: their crash
is in `VirtualAudio`, ours is in the CoreAudio host.

Do not spend another boot on the same variants. Either patch the host
`CoreAudio` framework in the dyld shared cache (not editable from this WSL
host: no `hfsplus` kernel module, `7z u` fails, `hfsutils` cannot mount HFS+)
or accept VirtualAudio disabled and route from our plug-in without it. The
other ports' fallback is exactly that: "no route, all clients see Null_Device".

## The in-process CoreAudio guard is not a fix (2026-11-28)

Patch 0512 injects `MondrianNullGuard.dylib` into mediaserverd when
`mondrianmsguard=1` and a dylib is present in `/private/var/vm`. The guard
uses `vm_protect` (kr=0) to patch the observed `ldr x8,[x0,#0x10]` at
CoreFoundation `__TEXT+0x7ab64` into `mov x8,#0`. Result: the original crash
site is avoided but mediaserverd crash-loops elsewhere (**93 corpses in one
boot**) because the same CF routine is used by many other paths. Do not ship
this guard; boot with `mondrianmsguard` absent. The NULL string needs a fix at
the caller in CoreAudio's DeviceManagerCreated, not a blanket instruction
replacement.

## Safari / WKWebView blank — `Lakr233/vphone-cli` issue #756 and `AdyaGMD/ios-spes/NOTES.md`

WebKit asks for `w30r`/`b3a8` (extended-colour, 10-bit) IOSurfaces. When the
kernel hands it plain BGRA, layout and JS work but nothing paints: only a
layer's backgroundColor shows. Forcing `MGGetBoolAnswer("HasExtendedColorDisplay")`
and `WebCore::screenSupportsExtendedColor()` to false makes WebKit use 8-bit
BGRA backing stores and pages render correctly, with nothing else changed. A
process hook (SystemHook/inserted dylib) in WebKit clients is enough. This is
the cheapest fix for our "Safari content is black; w30r surfaces stay zero"
(`docs/MONDIAN_PORT.md` §7), and it does not need GPU work. `ios-spes` reset
the MobileGestalt cache (`sweetmgreset=1`) for the same reason.

## The 8-bit colour hook on our port (2026-11-28)

The Gestalt interposer in `tools/mondrian-webkit-color.c` is injected by patch
0385 into `com.apple.WebKit.GPU` and by 0513 into
`com.apple.WebKit.WebContent` (before 0402's picture-bridge branch claims the
process). Measured: the kernel logs both injections and AMFI logs the dylib,
but WebKit still creates `0x77333072` (`w30r`) surfaces and the page remains
black. A further probe interposed `CVPixelBufferCreate` and
`CVPixelBufferCreateWithIOSurface` and logged format plus stack to file,
stderr and `syslog(LOG_ALERT)`. With `MobileSafari` and two `WebContent`
processes running (confirmed in the ring), **no interposer fired at all** —
not even the Gestalt ones — so `DYLD_INSERT_LIBRARIES` interposing is not
reaching these symbols in WebKit on this build. Neither `MGGetBoolAnswer` nor
`MGCopyAnswer` is ever called, so WebKit does not get the extended-colour
answer from MobileGestalt on this port. Do not repeat the Gestalt hook.

The wider reference directory (below) shows the real fix is rendering, not
colour negotiation: `AdyaGMD/ios-spes`, `andyleenz/pixel3-ios` and
`NWylynko/ios-flame` render Safari pages when CoreAnimation has an EAGL/Mesa
or Metal device, and `ios-spes` attributes working blur to a Metal allow-list
for `backboardd`. The next step is that GPU path, not another interposer.

## Camera — `DenialOfGravity/ios-redfin`, `EthanArbuckle/vcam-ios`

`ios-redfin` runs Camera.app with live preview and photos on IMX363/IMX355,
focus and flash from the kernel. `vcam-ios` establishes that `mediaserverd`
connects to the camera hardware and forwards frames to clients, and hooks
there to replace the image — the same interception point a port needs. Our
Photos path already works; Camera is the missing client.
The live device tree has camera plumbing — `reserved-memory/camera_region`,
six `qcom,csiphy*@ace*` blocks, `qcom,cam-isp`, `qcom,cam-cpas` and the
`cam_sensor_mclk*` pin states — but **no camera sensor node** (`imx*`, `ov*`,
`s5k*` are all absent). There is therefore no I2C address, CSI lane mapping or
sensor identity to bind a driver to, and `Camera.app` returns 0 from
`LSApplicationWorkspace openApplicationWithBundleID:`. There is no generic bus probe to close that gap: `usb-ring.py` advertises
`si`/`sr`/`sw`, but the kernel has no handler for them (the ring answers
`no answer`), and the only I2C code in the tree is the private bit-bang in
`mondrian_audio_probe.c` with its own hardwired pins. Scanning camera buses
would require mapping QUP/TLMM pins for a bank no node describes.

Bringing up a real
camera means discovering the sensor on the bus first; the BW-node injection
cannot help until a capture graph exists.

`coreycusick/ios-guacamole` gets a real preview and photos in Camera.app by
publishing `/dev/hakios-camera` from the kernel and handing raw frames to
`ISP.mediacapture`; `DenialOfGravity/ios-redfin` serves camera frames through
its `RedwoodAudio.driver`. Those are the implementation references once a
sensor is discovered; the tracker's BW-node map below is only the userland end.

`yiffysec/Wam-Bam-A-Free-Cam-VCam` (MIT, iOS 15-18) is the clearest map of
that point: `BWNodeOutput -emitSampleBuffer:`, `BWImageQueueSinkNode
-renderSampleBuffer:forInput:`, `BWRemoteQueueSinkNode`, `BWPhotoEncoderNode`
and `BWStillImageSampleBufferSinkNode` in mediaserverd (cameracaptured from
iOS 18); video sinks need `420v` and still sinks BGRA. It registers no new
AVCaptureDevice, so it still depends on a real capture graph existing — do
not assume it makes Camera.app work on a board with no camera device.

## Sensors and thermals — `DenialOfGravity/ios-redfin`, `ResistanceTo/MiniWatts`

`ios-redfin` runs `fastrpcd` (DSP FastRPC) and publishes accelerometer,
gyroscope, light, compass and pressure to iOS as HID services through `sensd`.
`MiniWatts` documents the private iOS APIs for the PMU and all 30 temperature
sensors (Apache-2.0). Our thermal/HID path should follow the same shape:
kernel publishes HID events, iOS sees IOHIDEventService; no Apple driver needed.

## Battery and charging — `ios-redfin`

`ios-redfin` reports real percentage from the fuel gauge (seeded, then
coulomb-counted) and still lists charging-while-iOS-runs as broken; charging
in the bootloader is the workaround. Ours already publishes the level via
`IOPMPowerSource`; the AP cannot control the SMB5, so do not expect charging
to work without a similar workaround.

## General

`jebbranch/ios-port-marble` (`docs/smmu-dead-ends.md`, `docs/gpu-probe.md`) and
`bangprovn/ios-fuxi` keep their negative results explicitly; read those before
re-testing a discarded approach. Both are iOS 16 generation and close to our
hardware.

## The wider reference directory (2026-11-28)

The six base projects are not the full picture: `GET /api/forks` on the tracker
lists **600 repos** with per-area evidence. Filtering them by subsystem found a
device-verified reference for every open area, often on iOS 16.7.16 and a
nearby Snapdragon:

- `DenialOfGravity/ios-redfin` runs iOS 16.7.16 with `RedwoodAudio.driver`
  serving speaker, microphone, haptics **and camera**, plus `wland`, `btd`,
  `fastrpcd`/`sensd`, Venus video, native Metal, auto-brightness, Night Shift
  and True Tone.
- `akshaynexus/iOSPlus10` with `akshaynexus/slop` (also
  `MellysInformejtik/slop`) carries 128 xnu-8796 patches for SM8450 and
  Metal2Vulkan, Wi-Fi, Bluetooth, audio, haptics, brightness and battery.
- `aTechGeekDev/ios-apollo` proves ath11k Wi-Fi, Bluetooth A2DP at 921600
  baud, AW8697 vibration, CS35L41 audio, brightness and a runaway-daemon
  limit of 10 % of a core on iOS 16.7.16.
- `andyleenz/pixel3-ios`, `joranv1/ios-sailfish` and `AdyaGMD/ios-spes` show
  Safari, text, App Library blur and stock wallpaper are GPU/EAGL/Metal
  results, not MobileGestalt results. `ios-sailfish` converts HEIC wallpaper
  layers to PNG at root-build time (`tools/wallpaper-heic2png.sh`).
- `UniXNU/QcaBluetooth` is the working Qualcomm Bluetooth driver with
  `BlueTool` and `Type0`; `coreycusick/ios-guacamole` publishes camera frames
  from `/dev/hakios-camera` to `ISP.mediacapture` and fixes audio cut-outs
  with a 24 MHz timebase on a 19.2 MHz timer.
- `FFT-infra/UniXNU-alioth` reaches `WALLPAPER stage=5` with a staged Metal
  device; `ry-diffusion/Crimson` is the maintained AIR→NIR→ir3 Metal frontend.
- `qiumochen/UniXNU-zizhan` and `Chengdong-Yu/pong-wifi` remain the same-SoC
  Wi-Fi authority already recorded in `REFERENCE_PORTS.md`.

Consequence: stop re-testing CoreAudio discovery, Gestalt interposers and the
BHI doorbell. Port the implementations above; files and licences are in
`REFERENCE_PORTS.md`.

## The sibling mondrian port (audited 2026-11-28)

[Emilelu/UniXNU-mondrian](https://github.com/Emilelu/UniXNU-mondrian) targets
the same phone. Its repo is archived; its current `main` is an iOS 27 stage-0
defconfig with no storage, display or GPU enabled, and its last
device-verified UI is SpringBoard on a **software renderer** (0.9-7.8 fps
against our 81-118 fps). It is not a source of UI or performance fixes. These
are the concrete deltas:

- **PAC gate (import first).** `patches/ios-mondrian/pac-probe-arm64e-gate.patch`
  (commits `f67aee8703`, `ec0863fe63`, `8cc3855376`) applies to our
  `shim/pac.c` and `shim/start.S`: `APA=5` is FEAT_PAuth (with EPAC and PAuth2),
  `API=0` only means no generic keys, and the exception frame restores
  `x29/x30` from `#272` with `add sp,#34*8`. Our note that pointer auth is
  "none" describes a compile choice, not the hardware. READ-ONLY on the donor
  side (offline objdump); one boot is still needed after import.
- **Layered transparency.** `patches/xnu/0600-k60-display-composition.patch`
  keeps unmentioned layers, composes old and new footprints with
  premultiplied-BGRA `sourceOver()` and writes only damaged rects. It is the
  only donor code aimed at transparency rather than one full-screen surface,
  but its own header says verification was not run. Treat as a candidate to
  diff against our `0085`, not as a proven fix.
- **Wallpaper selection.** `patches/xnu/0618-k60-wallpaper-seed.patch`,
  `userland/ui_compat.c:628-741` and
  `docs/research/springboard/WALLPAPER-CHAIN.md`: a staged still is not a
  selected wallpaper. The donor needed a native `WKSystemShellWallpaperManager`
  call and the correct `logicalScreenClass`; pixels were never confirmed.
- **Touch-driven responsiveness.** `patches/xnu/0626-k60-touch-activity.patch`
  and `drivers/PongPower/K60CpuFreqProbe.cpp` raise the P-domain to 1.8048 GHz
  in a ~1 s window from touch reports. This is the donor's only
  device-verified latency work and is the closest near-term lever for the
  app switcher. GPU DCVS in the same series is build-only.
- **Metal traps.** `drivers/PongMetal/PongMetalPlugin.mm`,
  `PongQuartzCorePolicy.h`, `seeds/PongAdrenoMetal.clients` and
  `docs/engineering/GPU-IOSURFACE-ROOT-CAUSE.md` §6: the plugin was deployed
  to `/private/var/ngpu/addons/` while the injector read `/private/var/pong/`,
  so no process ever loaded it and `MTLCreateSystemDefaultDevice()` stayed nil.
  A CA allow-list covers `backboardd`, `SpringBoard`, `CollectionsPoster`,
  `WidgetRenderer_Default`, `PosterBoard` and the poster extensions.
- **4 KiB pages are not excluded by the SoC.** The donor boots iOS 16.6.1 to
  SpringBoard at 4 KiB with `native-4k-*.patch`; our failure was deriving 4 KiB
  code-sign hashes from the 16 KiB cache, not a hardware limit.
- IOSurface renaming is a dead end (patches `0622`/`0623` retired); the donor's
  thermal status contradicts itself, so check a log before treating it as a
  result. Its sealed-root `bindfs` trap does not apply to our single HFS+
  volume, and its committed Bluetooth firmware blobs are not license-clean
  for this tree.

No adaptive text colour, text legibility fix, Safari rendering, HEIC wallpaper
converter or HFS+ work exists there; do not look for a UI fix in this donor.
